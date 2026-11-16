#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Remembers the frame and maximized state of a visible window for the next launch.
  void SavePlacement();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;
  LRESULT HitTest(POINT screen_point) const override;

 private:
  void HandleWindowMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void NotifyWindowState();
  flutter::EncodableMap WindowState() const;
  static LRESULT CALLBACK ChildSubclassProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam,
                                            UINT_PTR id, DWORD_PTR data);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::optional<RECT> maximize_button_;
  bool maximize_hovered_ = false;
  // Set once Dart listens on the window channel; from then on Dart decides whether a close request quits.
  bool dart_handles_close_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
