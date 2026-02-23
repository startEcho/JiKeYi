import AppKit

@main
enum JiKeYiTransMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
  }
}
