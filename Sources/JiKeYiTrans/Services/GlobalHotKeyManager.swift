import Carbon
import Foundation

private func hotKeyEventHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else {
    return noErr
  }
  let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
  return manager.handleEvent(event)
}

final class GlobalHotKeyManager {
  private struct Registration {
    let shortcut: String
    let ref: EventHotKeyRef
    let handler: () -> Void
  }

  private let hotKeySignature: OSType
  private var registrations: [UInt32: Registration] = [:]
  private var eventHandlerRef: EventHandlerRef?
  private var nextID: UInt32 = 1

  init(signature: OSType = 0x4A4B5954) { // JKYT
    hotKeySignature = signature
    installEventHandlerIfNeeded()
  }

  deinit {
    unregisterAll()
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }

  @discardableResult
  func register(shortcut: String, handler: @escaping () -> Void) -> UInt32? {
    guard let parsed = ShortcutParser.parse(shortcut) else {
      return nil
    }

    var hotKeyRef: EventHotKeyRef?
    let id = nextID
    nextID &+= 1

    let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
    let status = RegisterEventHotKey(
      parsed.keyCode,
      parsed.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )

    guard status == noErr, let hotKeyRef else {
      return nil
    }

    registrations[id] = Registration(shortcut: shortcut, ref: hotKeyRef, handler: handler)
    return id
  }

  func unregisterAll() {
    for registration in registrations.values {
      UnregisterEventHotKey(registration.ref)
    }
    registrations.removeAll()
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandlerRef == nil else {
      return
    }

    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      hotKeyEventHandler,
      1,
      &eventType,
      pointer,
      &eventHandlerRef
    )

    if status != noErr {
      eventHandlerRef = nil
    }
  }

  fileprivate func handleEvent(_ event: EventRef) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )

    guard status == noErr else {
      return OSStatus(eventNotHandledErr)
    }

    guard hotKeyID.signature == hotKeySignature else {
      return OSStatus(eventNotHandledErr)
    }

    guard let registration = registrations[hotKeyID.id] else {
      return OSStatus(eventNotHandledErr)
    }

    registration.handler()

    return noErr
  }
}

private enum ShortcutParser {
  struct ParsedShortcut {
    let keyCode: UInt32
    let modifiers: UInt32
  }

  private static let modifierMap: [String: UInt32] = [
    "commandorcontrol": UInt32(cmdKey),
    "command": UInt32(cmdKey),
    "cmd": UInt32(cmdKey),
    "control": UInt32(controlKey),
    "ctrl": UInt32(controlKey),
    "option": UInt32(optionKey),
    "alt": UInt32(optionKey),
    "shift": UInt32(shiftKey),
    "super": UInt32(cmdKey)
  ]

  private static let keyMap: [String: UInt32] = [
    "a": 0,
    "s": 1,
    "d": 2,
    "f": 3,
    "h": 4,
    "g": 5,
    "z": 6,
    "x": 7,
    "c": 8,
    "v": 9,
    "b": 11,
    "q": 12,
    "w": 13,
    "e": 14,
    "r": 15,
    "y": 16,
    "t": 17,
    "1": 18,
    "2": 19,
    "3": 20,
    "4": 21,
    "6": 22,
    "5": 23,
    "equal": 24,
    "9": 25,
    "7": 26,
    "minus": 27,
    "8": 28,
    "0": 29,
    "rightbracket": 30,
    "o": 31,
    "u": 32,
    "leftbracket": 33,
    "i": 34,
    "p": 35,
    "enter": 36,
    "l": 37,
    "j": 38,
    "quote": 39,
    "k": 40,
    "semicolon": 41,
    "backslash": 42,
    "comma": 43,
    "slash": 44,
    "n": 45,
    "m": 46,
    "period": 47,
    "tab": 48,
    "space": 49,
    "grave": 50,
    "backspace": 51,
    "esc": 53,
    "escape": 53,
    "delete": 117,
    "home": 115,
    "end": 119,
    "pageup": 116,
    "pagedown": 121,
    "left": 123,
    "right": 124,
    "down": 125,
    "up": 126,
    "f1": 122,
    "f2": 120,
    "f3": 99,
    "f4": 118,
    "f5": 96,
    "f6": 97,
    "f7": 98,
    "f8": 100,
    "f9": 101,
    "f10": 109,
    "f11": 103,
    "f12": 111,
    "num0": 82,
    "num1": 83,
    "num2": 84,
    "num3": 85,
    "num4": 86,
    "num5": 87,
    "num6": 88,
    "num7": 89,
    "num8": 91,
    "num9": 92,
    "numenter": 76,
    "numadd": 69,
    "numsub": 78,
    "numdiv": 75,
    "nummult": 67,
    "numdec": 65
  ]

  static func parse(_ rawShortcut: String) -> ParsedShortcut? {
    let components = rawShortcut
      .split(separator: "+")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }

    guard !components.isEmpty else {
      return nil
    }

    var modifiers: UInt32 = 0
    var keyToken: String?

    for token in components {
      if let modifier = modifierMap[token] {
        modifiers |= modifier
      } else {
        keyToken = token
      }
    }

    guard let keyToken else {
      return nil
    }

    let normalizedKey = normalizeKeyToken(keyToken)
    guard let keyCode = keyMap[normalizedKey] else {
      return nil
    }

    return ParsedShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  private static func normalizeKeyToken(_ token: String) -> String {
    switch token {
    case "-":
      return "minus"
    case "=":
      return "equal"
    case "[":
      return "leftbracket"
    case "]":
      return "rightbracket"
    case "`":
      return "grave"
    case ",":
      return "comma"
    case ".":
      return "period"
    case ";":
      return "semicolon"
    case "'":
      return "quote"
    case "\\":
      return "backslash"
    case "/":
      return "slash"
    case "arrowleft":
      return "left"
    case "arrowright":
      return "right"
    case "arrowup":
      return "up"
    case "arrowdown":
      return "down"
    case " ":
      return "space"
    default:
      return token
    }
  }
}
