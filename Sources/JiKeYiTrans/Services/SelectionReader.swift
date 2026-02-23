import AppKit
import ApplicationServices
import Foundation

struct SelectionPayload {
  let text: String
  let anchor: CGRect?
}

enum SelectionReaderError: LocalizedError {
  case accessibilityDenied
  case noFocusedElement
  case noSelection

  var errorDescription: String? {
    switch self {
    case .accessibilityDenied:
      return "缺少辅助功能权限，请在 系统设置 > 隐私与安全性 > 辅助功能 中允许本应用。"
    case .noFocusedElement:
      return "未找到当前聚焦的输入元素。"
    case .noSelection:
      return "未读取到选中文本。"
    }
  }
}

@MainActor
final class SelectionReader {
  init() {}

  func readSelection(promptIfNeeded: Bool = true) throws -> SelectionPayload {
    if !isAccessibilityEnabled(promptIfNeeded: promptIfNeeded) {
      throw SelectionReaderError.accessibilityDenied
    }

    let systemFocused = focusedElementFromSystemWide()
    if let systemFocused, let payload = makeSelectionPayload(from: systemFocused) {
      return payload
    }

    let appFocused = focusedElementFromFrontmostApp()
    if let appFocused, let payload = makeSelectionPayload(from: appFocused) {
      return payload
    }

    if systemFocused == nil && appFocused == nil {
      throw SelectionReaderError.noFocusedElement
    }

    throw SelectionReaderError.noSelection
  }

  func isAccessibilityEnabled(promptIfNeeded: Bool) -> Bool {
    if !promptIfNeeded {
      return AXIsProcessTrusted()
    }

    let options = [String("AXTrustedCheckOptionPrompt"): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private func focusedElementFromSystemWide() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
    guard error == .success, let value else {
      return nil
    }
    let element = value as! AXUIElement
    return element
  }

  private func focusedElementFromFrontmostApp() -> AXUIElement? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
    guard error == .success, let value else {
      return nil
    }
    let element = value as! AXUIElement
    return element
  }

  private func selectedText(from element: AXUIElement) -> String? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
    guard error == .success else {
      return nil
    }

    guard let text = value as? String else {
      return nil
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func selectedRange(from element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
    guard error == .success, let value else {
      return nil
    }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else {
      return nil
    }

    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else {
      return nil
    }

    return range
  }

  private func boundsForSelectedRange(from element: AXUIElement, range: CFRange) -> CGRect? {
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
    guard AXValueGetType(axValue) == .cgRect else {
      return nil
    }

    var rect = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &rect) else {
      return nil
    }

    return rect
  }

  private func elementFrame(from element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?

    let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
    let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

    guard positionError == .success, sizeError == .success, let positionValue, let sizeValue else {
      return nil
    }

    let positionAX = positionValue as! AXValue
    let sizeAX = sizeValue as! AXValue

    guard AXValueGetType(positionAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize else {
      return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionAX, .cgPoint, &point), AXValueGetValue(sizeAX, .cgSize, &size) else {
      return nil
    }

    return CGRect(origin: point, size: size)
  }

  private func makeSelectionPayload(from element: AXUIElement) -> SelectionPayload? {
    guard let text = selectedText(from: element) else {
      return nil
    }

    let range = selectedRange(from: element)
    let rangeBounds = range.flatMap { boundsForSelectedRange(from: element, range: $0) }
    let frameBounds = elementFrame(from: element)
    let anchor = rangeBounds ?? frameBounds

    return SelectionPayload(text: text, anchor: anchor)
  }
}
