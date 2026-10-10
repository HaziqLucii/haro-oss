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

    super.awakeFromNib()
  }
}
