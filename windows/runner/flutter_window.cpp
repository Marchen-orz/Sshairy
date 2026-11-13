#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>

#include <cmath>
#include <iterator>
#include <map>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

// Persisted accent names in the order of the IDI_BRAND_* ids, each with a light and a dark icon.
constexpr const char* kBrandThemes[] = {"blue", "green", "violet", "orange", "deepSea", "pink"};
constexpr int kBrandThemeCount = static_cast<int>(std::size(kBrandThemes));
static_assert(IDI_BRAND_PINK_DARK == IDI_BRAND_BLUE_LIGHT + 2 * kBrandThemeCount - 1,
              "brand icon ids must be contiguous");

// The icon resource for {'theme': name, 'dark': bool}, or nothing for anything outside the allowlist.
std::optional<int> BrandIconResource(const flutter::EncodableValue* arguments) {
  const auto* map = arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (map == nullptr) return std::nullopt;
  const auto theme = map->find(flutter::EncodableValue("theme"));
  const auto dark = map->find(flutter::EncodableValue("dark"));
  if (theme == map->end() || dark == map->end()) return std::nullopt;
  const auto* name = std::get_if<std::string>(&theme->second);
  const auto* is_dark = std::get_if<bool>(&dark->second);
  if (name == nullptr || is_dark == nullptr) return std::nullopt;
  for (int i = 0; i < kBrandThemeCount; ++i) {
    if (*name == kBrandThemes[i]) return IDI_BRAND_BLUE_LIGHT + i * 2 + (*is_dark ? 1 : 0);
  }
  return std::nullopt;
}

std::string Utf8(const std::wstring& text) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                                       nullptr, 0, nullptr, nullptr);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(), size,
                      nullptr, nullptr);
  return out;
}

int CALLBACK CollectFont(const LOGFONTW* font, const TEXTMETRICW* metric, DWORD, LPARAM data) {
  // Names starting with '@' are the vertical-writing variants of CJK fonts.
  if (font->lfFaceName[0] == L'@') return 1;
  auto& fonts = *reinterpret_cast<std::map<std::wstring, bool>*>(data);
  // The TMPF_FIXED_PITCH bit is set for variable-pitch fonts, despite its name.
  const bool mono = (metric->tmPitchAndFamily & TMPF_FIXED_PITCH) == 0;
  fonts.emplace(font->lfFaceName, mono);
  return 1;
}

// Installed font families as [name, monospaced] pairs.
flutter::EncodableList SystemFonts() {
  std::map<std::wstring, bool> fonts;
  LOGFONTW query = {};
  query.lfCharSet = DEFAULT_CHARSET;
  const HDC dc = GetDC(nullptr);
  EnumFontFamiliesExW(dc, &query, CollectFont, reinterpret_cast<LPARAM>(&fonts), 0);
  ReleaseDC(nullptr, dc);
  flutter::EncodableList list;
  for (const auto& [name, mono] : fonts) {
    list.push_back(flutter::EncodableValue(
        flutter::EncodableList{flutter::EncodableValue(Utf8(name)), flutter::EncodableValue(mono)}));
  }
  return list;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  HWND content = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(content);
  // The Flutter child covers the client area, including its invisible resize border.
  if (!SetWindowSubclass(content, ChildSubclassProc, 1,
                         reinterpret_cast<DWORD_PTR>(this))) {
    return false;
  }
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sshairy/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleWindowMethod(call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_.reset();
  if (flutter_controller_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                         ChildSubclassProc, 1);
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

flutter::EncodableMap FlutterWindow::WindowState() const {
  return {
      {flutter::EncodableValue("maximized"),
       flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE)},
      {flutter::EncodableValue("active"),
       flutter::EncodableValue(GetForegroundWindow() == GetHandle())},
      {flutter::EncodableValue("maximizeHovered"),
       flutter::EncodableValue(maximize_hovered_)},
  };
}

void FlutterWindow::NotifyWindowState() {
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "state", std::make_unique<flutter::EncodableValue>(WindowState()));
  }
}

void FlutterWindow::HandleWindowMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  const HWND window = GetHandle();
  if (method == "initialize") {
    dart_handles_close_ = true;
    result->Success(flutter::EncodableValue(WindowState()));
    return;
  }
  if (method == "fonts") {
    result->Success(flutter::EncodableValue(SystemFonts()));
    return;
  }
  if (method == "clipboardFiles") {
    if (!IsClipboardFormatAvailable(CF_HDROP)) {
      result->Success(flutter::EncodableValue(flutter::EncodableList{}));
      return;
    }
    if (!OpenClipboard(window)) {
      result->Error("attachmentUnreadable", "Clipboard is unavailable");
      return;
    }
    struct ClipboardGuard {
      ~ClipboardGuard() { CloseClipboard(); }
    } clipboard_guard;
    const HDROP drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
    if (drop == nullptr) {
      result->Error("attachmentUnreadable", "File clipboard is unavailable");
      return;
    }
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    if (count > 4) {
      result->Error("attachmentTooLarge", "Too many attachments");
      return;
    }
    flutter::EncodableList files;
    for (UINT i = 0; i < count; ++i) {
      const UINT length = DragQueryFileW(drop, i, nullptr, 0);
      if (length == 0 || length > 32767) {
        result->Error(length > 32767 ? "attachmentTooLarge" : "attachmentUnreadable",
                      "Invalid file clipboard entry");
        return;
      }
      std::wstring path(length + 1, L'\0');
      if (DragQueryFileW(drop, i, path.data(), length + 1) != length) {
        result->Error("attachmentUnreadable", "File clipboard changed");
        return;
      }
      path.resize(length);
      files.emplace_back(Utf8(path));
    }
    result->Success(flutter::EncodableValue(files));
    return;
  }
  if (method == "brandIcon") {
    const auto icon = BrandIconResource(call.arguments());
    if (!icon) {
      result->Error("invalid_icon", "Expected a known theme and a dark flag");
    } else if (!SetIcon(*icon)) {
      result->Error("icon_unavailable", "The window icon could not be loaded");
    } else {
      result->Success();
    }
    return;
  }
  if (method == "minimize") {
    ShowWindow(window, SW_MINIMIZE);
  } else if (method == "toggleMaximize") {
    ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
  } else if (method == "drag") {
    ReleaseCapture();
    SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  } else if (method == "hide") {
    ShowWindow(window, SW_HIDE);
  } else if (method == "show") {
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
  } else if (method == "systemMenu") {
    POINT point;
    GetCursorPos(&point);
    const HMENU menu = GetSystemMenu(window, FALSE);
    const bool maximized = IsZoomed(window) != FALSE;
    EnableMenuItem(menu, SC_RESTORE, MF_BYCOMMAND | (maximized ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, SC_MAXIMIZE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));
    const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                       point.x, point.y, 0, window, nullptr);
    if (command != 0) PostMessage(window, WM_SYSCOMMAND, command, 0);
  } else if (method == "maximizeRect") {
    if (call.arguments() == nullptr ||
        std::holds_alternative<std::monostate>(*call.arguments())) {
      maximize_button_.reset();
    } else {
      const auto* bounds = std::get_if<flutter::EncodableList>(call.arguments());
      if (bounds == nullptr || bounds->size() != 4) {
        result->Error("invalid_bounds", "Expected four coordinates");
        return;
      }
      LONG coordinates[4];
      for (int i = 0; i < 4; ++i) {
        const auto* number = std::get_if<double>(&(*bounds)[i]);
        if (number == nullptr || !std::isfinite(*number) || *number < 0 || *number > 100000) {
          result->Error("invalid_bounds", "Invalid coordinate");
          return;
        }
        coordinates[i] = static_cast<LONG>(std::lround(*number));
      }
      maximize_button_ = RECT{coordinates[0], coordinates[1], coordinates[2], coordinates[3]};
    }
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

LRESULT FlutterWindow::HitTest(POINT point) const {
  const LRESULT edge = Win32Window::HitTest(point);
  if (edge != HTCLIENT) return edge;
  if (maximize_button_) {
    ScreenToClient(GetHandle(), &point);
    if (PtInRect(&*maximize_button_, point)) return HTMAXBUTTON;
  }
  return HTCLIENT;
}

LRESULT CALLBACK FlutterWindow::ChildSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR id, DWORD_PTR data) {
  auto* self = reinterpret_cast<FlutterWindow*>(data);
  if (message == WM_NCHITTEST &&
      self->HitTest({GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}) != HTCLIENT) {
    // Hit testing continues in the parent on the same thread, retaining native Snap behaviour.
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, ChildSubclassProc, id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                     WPARAM const wparam,
                                     LPARAM const lparam) noexcept {
  // Client-frame geometry must be applied before the engine's default non-client handling.
  if (message == WM_NCCALCSIZE || message == WM_NCHITTEST ||
      message == WM_GETMINMAXINFO) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  // Without a system frame DefWindowProc neither draws nor acts on the maximize button, so the click reported
  // over Flutter's button (HTMAXBUTTON keeps Snap Layouts) is carried out here.
  if (wparam == HTMAXBUTTON) {
    if (message == WM_NCLBUTTONDOWN || message == WM_NCLBUTTONDBLCLK) return 0;
    if (message == WM_NCLBUTTONUP) {
      ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
      return 0;
    }
  }
  // Alt+F4, the taskbar and the system menu ask Dart, which confirms and shuts down as the close button does and
  // quits the message loop itself. The engine's own close handling let the window go without asking.
  if (message == WM_CLOSE && dart_handles_close_ && window_channel_) {
    window_channel_->InvokeMethod("closeRequested", nullptr);
    return 0;
  }
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
  }
  switch (message) {
    case WM_NCMOUSEMOVE: {
      const bool hovering = wparam == HTMAXBUTTON;
      if (hovering != maximize_hovered_) {
        maximize_hovered_ = hovering;
        NotifyWindowState();
      }
      TRACKMOUSEEVENT tracking = {sizeof(TRACKMOUSEEVENT), TME_LEAVE | TME_NONCLIENT, hwnd, 0};
      TrackMouseEvent(&tracking);
      break;
    }
    case WM_NCMOUSELEAVE:
      maximize_hovered_ = false;
      NotifyWindowState();
      break;
    case WM_SIZE:
    case WM_ACTIVATE: {
      const auto response = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      NotifyWindowState();
      return response;
    }
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
