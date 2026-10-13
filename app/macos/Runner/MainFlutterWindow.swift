import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Posting from the app itself (not osascript) is what puts haro's icon and name on the
    // banner instead of Script Editor's.
    let notify = FlutterMethodChannel(
      name: "dev.haro.haroApp/notify",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    notify.setMethodCallHandler { call, result in
      if call.method == "status" {
        // Allowed? true / false; nil while macOS has not asked yet. No banner is sent.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          switch settings.authorizationStatus {
          case .authorized, .provisional: result(true)
          case .denied: result(false)
          default: result(nil)
          }
        }
        return
      }
      guard call.method == "show",
        let args = call.arguments as? [String: String]
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let center = UNUserNotificationCenter.current()
      center.requestAuthorization(options: [.alert]) { granted, _ in
        guard granted else {
          result(false)
          return
        }
        let content = UNMutableNotificationContent()
        content.title = args["title"] ?? "haro"
        content.body = args["body"] ?? ""
        let request = UNNotificationRequest(
          identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in result(error == nil) }
      }
    }

    // A copied picture (a screenshot, an image from a browser) as PNG bytes, for pasting into a
    // note. nil when the clipboard holds no image, or holds text too: the text paste then goes on as usual.
    let clipboard = FlutterMethodChannel(
      name: "dev.haro.haroApp/clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    clipboard.setMethodCallHandler { call, result in
      guard call.method == "readImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let pb = NSPasteboard.general
      // Cells copied from a spreadsheet, or a file copied in Finder, carry a picture beside the
      // text: text wins, so only a clipboard with no text is taken as an image.
      if pb.string(forType: .string) != nil {
        result(nil)
        return
      }
      if let png = pb.data(forType: .png) {
        result(FlutterStandardTypedData(bytes: png))
        return
      }
      if let tiff = pb.data(forType: .tiff),
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      {
        result(FlutterStandardTypedData(bytes: png))
        return
      }
      result(nil)
    }

    super.awakeFromNib()
  }
}
