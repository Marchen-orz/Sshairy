import Cocoa
import FlutterMacOS

// shortcut: Flutter 3.47's macOS engine reads this Objective-C getter on its project; recheck when upgrading Flutter.
private final class RendererProject: FlutterDartProject {
  private let impeller: Bool

  init(impeller: Bool) {
    self.impeller = impeller
    super.init(precompiledDartBundle: nil)
  }

  @objc func enableImpeller() -> Bool { impeller }
}

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel?
  private var dartHandlesClose = false
  private var requestingClose = false
  private let themes = ["blue", "green", "violet", "orange", "deepSea", "pink"]

  override func awakeFromNib() {
    let impeller = rendererPreference()
    let project = RendererProject(impeller: impeller)
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
      .filter { !$0.hasPrefix("--renderer=") } + [impeller ? "--renderer=impeller" : "--renderer=skia"]
    let controller = FlutterViewController(project: project)
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    // AppKit restores the last frame under this name and saves every move or resize.
    setFrameAutosaveName("SshairyMainWindow")
    delegate = self

    RegisterGeneratedPlugins(registry: controller)
    let bridge = FlutterMethodChannel(name: "sshairy/window", binaryMessenger: controller.engine.binaryMessenger)
    channel = bridge
    bridge.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterMethodNotImplemented); return }
      self.handle(call, result: result)
    }
    super.awakeFromNib()
  }

  private func rendererPreference() -> Bool {
    if ProcessInfo.processInfo.environment["SSHAIRY_TEST_ISOLATED"] == "1" { return false }
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
          let identifier = Bundle.main.bundleIdentifier else { return true }
    let path = support.appendingPathComponent(identifier).appendingPathComponent("settings.json")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
          let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
          let data = try? Data(contentsOf: path),
          let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
    return settings["renderer"] as? String != "skia"
  }

  private func windowState() -> [String: Any] {
    // macOS keeps its traffic lights and native frame; the Dart bridge must not draw duplicate buttons.
    return ["maximized": isZoomed, "active": isKeyWindow, "maximizeHovered": false, "customChrome": false]
  }

  private func notifyState() {
    if dartHandlesClose { channel?.invokeMethod("state", arguments: windowState()) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      dartHandlesClose = true
      result(windowState())
    case "fonts":
      let manager = NSFontManager.shared
      let families = Set(manager.availableFontFamilies).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      result(families.map { family -> [Any] in
        let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12)
        return [family, font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false]
      })
    case "clipboardFiles":
      clipboardFiles(result)
    case "brandIcon":
      guard let args = call.arguments as? [String: Any], let theme = args["theme"] as? String,
            let dark = args["dark"] as? Bool, themes.contains(theme) else {
        result(FlutterError(code: "invalid_icon", message: "Expected a known theme and a dark flag", details: nil))
        return
      }
      guard let icon = brandIcon(theme: theme, dark: dark) else {
        result(FlutterError(code: "icon_unavailable", message: "The window icon could not be loaded", details: nil))
        return
      }
      NSApp.applicationIconImage = icon
      miniwindowImage = icon
      result(nil)
    case "minimize":
      miniaturize(nil)
      result(nil)
    case "toggleMaximize":
      zoom(nil)
      result(nil)
    case "drag":
      if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseDragged {
        performDrag(with: event)
      }
      result(nil)
    case "hide":
      orderOut(nil)
      result(nil)
    case "show":
      if isMiniaturized { deminiaturize(nil) }
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    case "systemMenu":
      // Reuse the application's native Window menu rather than inventing a second set of window actions.
      if let menu = NSApp.windowsMenu, let view = contentView,
         let event = NSEvent.mouseEvent(with: .rightMouseDown, location: mouseLocationOutsideOfEventStream,
                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
        NSMenu.popUpContextMenu(menu, with: event, for: view)
      }
      result(nil)
    case "maximizeRect":
      result(nil) // Windows Snap hit testing has no equivalent in the native macOS frame.
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func clipboardFiles(_ result: FlutterResult) {
    let board = NSPasteboard.general
    let count = board.pasteboardItems?.filter { $0.types.contains(.fileURL) }.count ?? 0
    guard count <= 64 else {
      result(FlutterError(code: "attachmentTooMany", message: "Too many attachments", details: nil))
      return
    }
    let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard urls.count <= 64 else {
      result(FlutterError(code: "attachmentTooMany", message: "Too many attachments", details: nil))
      return
    }
    var files: [String] = []
    for url in urls {
      guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
            !url.path.isEmpty, url.path.utf16.count <= 32767, !url.path.contains("\0") else {
        result(FlutterError(code: "attachmentUnreadable", message: "Invalid file clipboard entry", details: nil))
        return
      }
      files.append(url.path)
    }
    result(files)
  }

  private func brandIcon(theme: String, dark: Bool) -> NSImage? {
    guard let index = themes.firstIndex(of: theme), let frameworks = Bundle.main.privateFrameworksURL else { return nil }
    let path = frameworks.appendingPathComponent("App.framework/Resources/flutter_assets/assets/brand/\(theme)/mark.png")
    guard let mark = NSImage(contentsOf: path) else { return nil }
    let light = [0xF1F7FF, 0xF1FAF6, 0xF7F3FD, 0xFFF7EE, 0xF0F6FC, 0xFFF4F8]
    let night = [0x121418, 0x0C1916, 0x14111E, 0x1D1510, 0x0A131F, 0x1D121A]
    let rgb = (dark ? night : light)[index]
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.lockFocus()
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 512, height: 512), xRadius: 108, yRadius: 108).fill()
    mark.draw(in: NSRect(x: 48, y: 100, width: 416, height: 312))
    image.unlockFocus()
    return image
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard dartHandlesClose, let channel = channel else { return true }
    if !requestingClose {
      requestingClose = true
      channel.invokeMethod("closeRequested", arguments: nil) { [weak self] _ in self?.requestingClose = false }
    }
    return false
  }

  func windowDidResize(_ notification: Notification) { notifyState() }
  func windowDidBecomeKey(_ notification: Notification) { notifyState() }
  func windowDidResignKey(_ notification: Notification) { notifyState() }
  func windowDidMiniaturize(_ notification: Notification) { notifyState() }
  func windowDidDeminiaturize(_ notification: Notification) { notifyState() }
}
