import AppKit
import ApplicationServices
import Foundation

func writeStderr(_ text: String) {
  if let data = (text + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

func postKey(
  source: CGEventSource,
  keyCode: CGKeyCode,
  keyDown: Bool,
  flags: CGEventFlags
) -> Bool {
  guard let event = CGEvent(
    keyboardEventSource: source,
    virtualKey: keyCode,
    keyDown: keyDown
  ) else {
    return false
  }

  event.flags = flags
  event.post(tap: .cghidEventTap)
  return true
}

if !AXIsProcessTrusted() {
  writeStderr("ACCESSIBILITY_DENIED")
  exit(1)
}

guard let source = CGEventSource(stateID: .hidSystemState) else {
  writeStderr("CGEVENT_SOURCE_FAILED")
  exit(1)
}

let commandKey: CGKeyCode = 55
let cKey: CGKeyCode = 8

let cmdDown = postKey(source: source, keyCode: commandKey, keyDown: true, flags: .maskCommand)
usleep(7000)
let cDown = postKey(source: source, keyCode: cKey, keyDown: true, flags: .maskCommand)
usleep(7000)
let cUp = postKey(source: source, keyCode: cKey, keyDown: false, flags: .maskCommand)
usleep(7000)
let cmdUp = postKey(source: source, keyCode: commandKey, keyDown: false, flags: [])

if cmdDown && cDown && cUp && cmdUp {
  print("OK")
  exit(0)
}

writeStderr("COPY_TRIGGER_FAILED")
exit(1)

