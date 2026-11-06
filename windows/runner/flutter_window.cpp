#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <cmath>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
    result->Success(flutter::EncodableValue(WindowState()));
    return;
  }
  if (method == "minimize") {
    ShowWindow(window, SW_MINIMIZE);
  } else if (method == "toggleMaximize") {
    ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
  } else if (method == "drag") {
    ReleaseCapture();
    SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
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
