import AppKit
import ApplicationServices
import Foundation

struct ClickPayload: Codable {
  let type: String
  let timestamp: Double
}

func writeStderr(_ text: String) {
  if let data = (text + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

func emitMouseDown() {
  let payload = ClickPayload(
    type: "mouse_down",
    timestamp: Date().timeIntervalSince1970
  )
  let encoder = JSONEncoder()
  do {
    let data = try encoder.encode(payload)
    if let text = String(data: data, encoding: .utf8) {
      print(text)
      fflush(stdout)
    }
  } catch {
    writeStderr("ENCODE_FAILED")
  }
}

if !AXIsProcessTrusted() {
  writeStderr("ACCESSIBILITY_DENIED")
  exit(1)
}

_ = NSApplication.shared

let globalMonitor = NSEvent.addGlobalMonitorForEvents(
  matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
) { _ in
  emitMouseDown()
}

if globalMonitor == nil {
  writeStderr("MONITOR_INIT_FAILED")
  exit(1)
}

RunLoop.main.run()

