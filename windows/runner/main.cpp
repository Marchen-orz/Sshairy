#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.h>

#include <cwchar>
#include <fstream>
#include <memory>
#include <optional>
#include <regex>
#include <sstream>

#include "flutter_window.h"
#include "utils.h"

// Impeller unless the user chose Skia (docs/DESIGN.md ADR-11). The engine takes the renderer only at startup,
// so this reads the settings file the app writes. The path is what path_provider derives from Runner.rc
// (CompanyName\ProductName under the roaming app data folder).
static bool UseImpeller() {
  // Integration tests inject temporary Dart data; skip the native preference read as well. They run Skia unless
  // SSHAIRY_TEST_IMPELLER=1, which the frame-timing probe uses to compare both.
  wchar_t isolated[2] = {};
  if (::GetEnvironmentVariableW(L"SSHAIRY_TEST_ISOLATED", isolated, 2) == 1 &&
      isolated[0] == L'1') {
    wchar_t impeller[2] = {};
    return ::GetEnvironmentVariableW(L"SSHAIRY_TEST_IMPELLER", impeller, 2) == 1 && impeller[0] == L'1';
  }
  wchar_t *app_data = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &app_data))) {
    ::CoTaskMemFree(app_data);
    return true;
  }
  std::wstring path = std::wstring(app_data) + L"\\dev.sshairy\\sshairy\\settings.json";
  ::CoTaskMemFree(app_data);
  std::ifstream file(path);
  std::stringstream text;
  text << file.rdbuf();
  return !std::regex_search(text.str(), std::regex(R"("renderer"\s*:\s*"skia")"));
}

// Updating a running installation would keep its executable and DLLs locked.
// A detached copy of the runner waits for the old process, without starting Flutter.
static std::optional<int> FinishUpdate() {
  int count = 0;
  std::unique_ptr<wchar_t*, decltype(&::LocalFree)> args(
      ::CommandLineToArgvW(::GetCommandLineW(), &count), ::LocalFree);
  if (!args || count < 2 || std::wcscmp(args.get()[1], L"--finish-update") != 0) {
    return std::nullopt;
  }
  if (count != 4) return EXIT_FAILURE;
  const wchar_t* pid_text = args.get()[2];
  wchar_t* end = nullptr;
  const DWORD pid = std::wcstoul(pid_text, &end, 10);
  if (end == pid_text || *end != L'\0' || pid == 0 || pid == ::GetCurrentProcessId()) {
    return EXIT_FAILURE;
  }
  const HANDLE parent = ::OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (parent != nullptr) {
    const DWORD result = ::WaitForSingleObject(parent, 120 * 1000);
    ::CloseHandle(parent);
    if (result != WAIT_OBJECT_0) return EXIT_FAILURE;
  } else if (::GetLastError() != ERROR_INVALID_PARAMETER) {
    return EXIT_FAILURE;
  }

  SHELLEXECUTEINFOW launch = {};
  launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_NOASYNC;
  launch.lpVerb = L"open";
  launch.lpFile = args.get()[3];
  launch.nShow = SW_SHOWNORMAL;
  return ::ShellExecuteExW(&launch) ? EXIT_SUCCESS : EXIT_FAILURE;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (const auto update = FinishUpdate()) {
    ::CoUninitialize();
    return *update;
  }

  // An ID no shortcut carries: under the implicit one the taskbar button takes the icon of the Start menu shortcut
  // that targets this exe and ignores the window icons switched with the theme.
  ::SetCurrentProcessExplicitAppUserModelID(L"dev.sshairy.sshairy");

  flutter::DartProject project(L"data");

  bool impeller = UseImpeller();
  project.set_impeller_switch(impeller ? flutter::ImpellerSwitch::Enabled
                                       : flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  command_line_arguments.push_back(impeller ? "--renderer=impeller"
                                            : "--renderer=skia");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Sshairy", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  window.SavePlacement();
  // Engine teardown can take seconds; it must not leave a frozen window on screen.
  ::ShowWindow(window.GetHandle(), SW_HIDE);

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
