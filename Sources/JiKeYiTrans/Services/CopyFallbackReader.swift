import AppKit
import ApplicationServices
import Foundation

@MainActor
final class CopyFallbackReader {
  init() {}

  func readSelectionText(timeout: TimeInterval = 0.9) -> String? {
    guard AXIsProcessTrusted() else {
      return nil
    }

    let pasteboard = NSPasteboard.general
    let previousString = pasteboard.string(forType: .string)
    let previousChangeCount = pasteboard.changeCount

    guard triggerCopyShortcut() else {
      return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    var capturedText: String?

    while Date() < deadline {
      if pasteboard.changeCount != previousChangeCount {
        let value = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
          capturedText = value
          break
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    restoreClipboard(previousString)
    return capturedText
  }

  private func restoreClipboard(_ previousString: String?) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let previousString {
      pasteboard.setString(previousString, forType: .string)
    }
  }

  private func triggerCopyShortcut() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      return false
    }

    let commandKey: CGKeyCode = 55
    let cKey: CGKeyCode = 8

    let cmdDown = postKey(source: source, keyCode: commandKey, keyDown: true, flags: .maskCommand)
    usleep(7_000)
    let cDown = postKey(source: source, keyCode: cKey, keyDown: true, flags: .maskCommand)
    usleep(7_000)
    let cUp = postKey(source: source, keyCode: cKey, keyDown: false, flags: .maskCommand)
    usleep(7_000)
    let cmdUp = postKey(source: source, keyCode: commandKey, keyDown: false, flags: [])

    return cmdDown && cDown && cUp && cmdUp
  }

  private func postKey(
    source: CGEventSource,
    keyCode: CGKeyCode,
    keyDown: Bool,
    flags: CGEventFlags
  ) -> Bool {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
      return false
    }

    event.flags = flags
    event.post(tap: .cghidEventTap)
    return true
  }
}
