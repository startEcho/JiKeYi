import Cocoa
import ApplicationServices

enum SelectionReaderError: String {
  case accessibilityDenied = "ACCESSIBILITY_DENIED"
  case noFocusedElement = "NO_FOCUSED_ELEMENT"
  case noSelection = "NO_SELECTION"
}

struct SelectionAnchor: Codable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

struct SelectionPayload: Codable {
  let text: String
  let anchor: SelectionAnchor?
}

func writeStderr(_ text: String) {
  if let data = (text + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

func focusedElementFromSystemWide() -> AXUIElement? {
  let systemWide = AXUIElementCreateSystemWide()
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(
    systemWide,
    kAXFocusedUIElementAttribute as CFString,
    &value
  )
  guard error == .success, let value else {
    return nil
  }
  return (value as! AXUIElement)
}

func focusedElementFromFrontmostApp() -> AXUIElement? {
  guard let frontmost = NSWorkspace.shared.frontmostApplication else {
    return nil
  }
  let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(
    appElement,
    kAXFocusedUIElementAttribute as CFString,
    &value
  )
  guard error == .success, let value else {
    return nil
  }
  return (value as! AXUIElement)
}

func selectedText(from element: AXUIElement) -> String? {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(
    element,
    kAXSelectedTextAttribute as CFString,
    &value
  )
  guard error == .success else {
    return nil
  }

  if let text = value as? String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  return nil
}

func selectedRange(from element: AXUIElement) -> CFRange? {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(
    element,
    kAXSelectedTextRangeAttribute as CFString,
    &value
  )
  guard error == .success, let value else {
    return nil
  }
  let axValue = value as! AXValue
  if AXValueGetType(axValue) != .cfRange {
    return nil
  }

  var range = CFRange()
  guard AXValueGetValue(axValue, .cfRange, &range) else {
    return nil
  }
  return range
}

func boundsForSelectedRange(from element: AXUIElement, range: CFRange) -> CGRect? {
  var mutableRange = range
  guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
    return nil
  }

  var value: CFTypeRef?
  let error = AXUIElementCopyParameterizedAttributeValue(
    element,
    kAXBoundsForRangeParameterizedAttribute as CFString,
    rangeValue,
    &value
  )
  guard error == .success, let value else {
    return nil
  }
  let axValue = value as! AXValue
  if AXValueGetType(axValue) != .cgRect {
    return nil
  }

  var rect = CGRect.zero
  guard AXValueGetValue(axValue, .cgRect, &rect) else {
    return nil
  }
  return rect
}

func elementFrame(from element: AXUIElement) -> CGRect? {
  var positionValue: CFTypeRef?
  var sizeValue: CFTypeRef?
  let positionError = AXUIElementCopyAttributeValue(
    element,
    kAXPositionAttribute as CFString,
    &positionValue
  )
  let sizeError = AXUIElementCopyAttributeValue(
    element,
    kAXSizeAttribute as CFString,
    &sizeValue
  )
  guard positionError == .success, sizeError == .success, let positionValue, let sizeValue else {
    return nil
  }

  let positionAX = positionValue as! AXValue
  let sizeAX = sizeValue as! AXValue
  if AXValueGetType(positionAX) != .cgPoint || AXValueGetType(sizeAX) != .cgSize {
    return nil
  }

  var point = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionAX, .cgPoint, &point), AXValueGetValue(sizeAX, .cgSize, &size) else {
    return nil
  }
  return CGRect(origin: point, size: size)
}

func normalizeAnchor(from rect: CGRect?) -> SelectionAnchor? {
  guard let rect else {
    return nil
  }

  let width = max(1.0, rect.width)
  let height = max(1.0, rect.height)
  return SelectionAnchor(
    x: Double(rect.origin.x),
    y: Double(rect.origin.y),
    width: Double(width),
    height: Double(height)
  )
}

func makeSelectionPayload(from element: AXUIElement) -> SelectionPayload? {
  guard let text = selectedText(from: element) else {
    return nil
  }

  let range = selectedRange(from: element)
  var rangeBounds: CGRect?
  if let range {
    rangeBounds = boundsForSelectedRange(from: element, range: range)
  }
  let frameBounds = elementFrame(from: element)
  let anchor = normalizeAnchor(from: rangeBounds ?? frameBounds)

  return SelectionPayload(text: text, anchor: anchor)
}

func emitPayload(_ payload: SelectionPayload) {
  let encoder = JSONEncoder()
  do {
    let data = try encoder.encode(payload)
    if let text = String(data: data, encoding: .utf8) {
      print(text)
      return
    }
  } catch {
    // ignore and fallback to plain text output
  }

  print(payload.text)
}

if !AXIsProcessTrusted() {
  writeStderr(SelectionReaderError.accessibilityDenied.rawValue)
  exit(1)
}

let systemFocused = focusedElementFromSystemWide()
if let systemFocused, let payload = makeSelectionPayload(from: systemFocused) {
  emitPayload(payload)
  exit(0)
}

let appFocused = focusedElementFromFrontmostApp()
if let appFocused, let payload = makeSelectionPayload(from: appFocused) {
  emitPayload(payload)
  exit(0)
}

if systemFocused == nil && appFocused == nil {
  writeStderr(SelectionReaderError.noFocusedElement.rawValue)
  exit(1)
}

writeStderr(SelectionReaderError.noSelection.rawValue)
exit(1)
