import AppKit
import ApplicationServices
import Foundation

@MainActor
final class SelectionReplacementWriter {
  init() {}

  func replaceSelectionText(with text: String, targetProcessIdentifier: pid_t?) -> Bool {
    let replacement = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !replacement.isEmpty, AXIsProcessTrusted() else {
      return false
    }

    let pasteboard = NSPasteboard.general
    let previousString = pasteboard.string(forType: .string)

    pasteboard.clearContents()
    pasteboard.setString(replacement, forType: .string)

    if let pid = targetProcessIdentifier,
       let targetApp = NSRunningApplication(processIdentifier: pid),
       !targetApp.isTerminated
    {
      targetApp.activate(options: [.activateIgnoringOtherApps])
      RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    }

    let pasted = triggerPasteShortcut()
    RunLoop.current.run(until: Date().addingTimeInterval(0.10))

    pasteboard.clearContents()
    if let previousString {
      pasteboard.setString(previousString, forType: .string)
    }

    return pasted
  }

  private func triggerPasteShortcut() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      return false
    }

    let commandKey: CGKeyCode = 55
    let vKey: CGKeyCode = 9

    let cmdDown = postKey(source: source, keyCode: commandKey, keyDown: true, flags: .maskCommand)
    usleep(7_000)
    let vDown = postKey(source: source, keyCode: vKey, keyDown: true, flags: .maskCommand)
    usleep(7_000)
    let vUp = postKey(source: source, keyCode: vKey, keyDown: false, flags: .maskCommand)
    usleep(7_000)
    let cmdUp = postKey(source: source, keyCode: commandKey, keyDown: false, flags: [])

    return cmdDown && vDown && vUp && cmdUp
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
