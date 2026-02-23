import AppKit
import CoreGraphics
import Foundation
import Vision

enum OCRReaderError: LocalizedError, Equatable {
  case screenRecordingDenied
  case noScreen
  case cancelled
  case captureFailed
  case emptyResult
  case recognitionFailed(String)

  var errorDescription: String? {
    switch self {
    case .screenRecordingDenied:
      return "缺少屏幕录制权限，请在 系统设置 > 隐私与安全性 > 屏幕录制 中允许本应用。"
    case .noScreen:
      return "未检测到可用屏幕。"
    case .cancelled:
      return "已取消截图 OCR。"
    case .captureFailed:
      return "截图失败，请重试。"
    case .emptyResult:
      return "未识别到可翻译文本。"
    case let .recognitionFailed(reason):
      return "OCR 识别失败：\(reason)"
    }
  }
}

@MainActor
final class OCRReader {
  private let selector = ScreenRegionSelector()

  func readSelection() async throws -> SelectionPayload {
    try ensureScreenRecordingPermission()
    let selectedRect = try await selector.selectRegion()
    let image = try captureImage(in: selectedRect)
    let text = try await recognizeText(in: image)

    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw OCRReaderError.emptyResult
    }

    return SelectionPayload(text: normalized, anchor: selectedRect)
  }

  private func ensureScreenRecordingPermission() throws {
    if #available(macOS 10.15, *) {
      guard CGPreflightScreenCaptureAccess() else {
        _ = CGRequestScreenCaptureAccess()
        throw OCRReaderError.screenRecordingDenied
      }
    }
  }

  private func captureImage(in rect: CGRect) throws -> CGImage {
    let target = rect.standardized.integral
    guard target.width >= 2, target.height >= 2 else {
      throw OCRReaderError.cancelled
    }

    guard let image = CGWindowListCreateImage(
      target,
      .optionOnScreenOnly,
      kCGNullWindowID,
      [.bestResolution, .boundsIgnoreFraming]
    ) else {
      throw OCRReaderError.captureFailed
    }
    return image
  }

  private func recognizeText(in image: CGImage) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let text = try Self.recognizeTextSync(in: image)
          continuation.resume(returning: text)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  nonisolated private static func recognizeTextSync(in image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.minimumTextHeight = 0.01

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      throw OCRReaderError.recognitionFailed(error.localizedDescription)
    }

    let observations = request.results ?? []
    let sorted = observations.sorted { lhs, rhs in
      let yDiff = lhs.boundingBox.maxY - rhs.boundingBox.maxY
      if abs(yDiff) > 0.02 {
        return yDiff > 0
      }
      return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    let lines = sorted.compactMap { observation -> String? in
      guard let candidate = observation.topCandidates(1).first?.string else {
        return nil
      }
      let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }

    return lines.joined(separator: "\n")
  }
}

@MainActor
private final class ScreenRegionSelector {
  private var activeWindow: SelectionOverlayWindow?
  private var continuation: CheckedContinuation<CGRect, Error>?

  func selectRegion() async throws -> CGRect {
    guard continuation == nil else {
      throw OCRReaderError.cancelled
    }

    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
    else {
      throw OCRReaderError.noScreen
    }

    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation

      let window = SelectionOverlayWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false,
        screen: screen
      )
      window.level = .screenSaver
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.ignoresMouseEvents = false

      let overlay = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
      overlay.onSelection = { [weak self] rect in
        self?.finish(with: rect)
      }

      window.contentView = overlay
      window.onEscape = { [weak self] in
        self?.finish(with: nil)
      }

      activeWindow = window
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func finish(with rect: CGRect?) {
    defer {
      activeWindow?.orderOut(nil)
      activeWindow = nil
      continuation = nil
    }

    guard let continuation else {
      return
    }

    guard let rect else {
      continuation.resume(throwing: OCRReaderError.cancelled)
      return
    }

    let normalized = rect.standardized
    guard normalized.width >= 6, normalized.height >= 6 else {
      continuation.resume(throwing: OCRReaderError.cancelled)
      return
    }

    continuation.resume(returning: normalized)
  }
}

private final class SelectionOverlayWindow: NSWindow {
  var onEscape: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onEscape?()
      return
    }
    super.keyDown(with: event)
  }
}

private final class SelectionOverlayView: NSView {
  var onSelection: ((CGRect?) -> Void)?

  private var dragStartPoint: CGPoint?
  private var dragCurrentPoint: CGPoint?

  override var acceptsFirstResponder: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    dragStartPoint = point
    dragCurrentPoint = point
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard dragStartPoint != nil else {
      return
    }
    dragCurrentPoint = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let start = dragStartPoint else {
      onSelection?(nil)
      return
    }

    let end = convert(event.locationInWindow, from: nil)
    dragCurrentPoint = end

    let localRect = NSRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )

    guard let window else {
      onSelection?(nil)
      return
    }

    if localRect.width < 2 || localRect.height < 2 {
      onSelection?(nil)
      return
    }

    let screenRect = window.convertToScreen(localRect)
    onSelection?(screenRect)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let overlayPath = NSBezierPath(rect: bounds)
    if let rect = currentSelectionRect() {
      overlayPath.append(NSBezierPath(rect: rect))
      overlayPath.windingRule = .evenOdd
    }
    NSColor.black.withAlphaComponent(0.42).setFill()
    overlayPath.fill()

    if let rect = currentSelectionRect() {
      NSColor.systemBlue.withAlphaComponent(0.92).setStroke()
      let border = NSBezierPath(rect: rect)
      border.lineWidth = 2
      border.stroke()

      let hint = "松开鼠标开始 OCR 翻译"
      let attrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
      ]
      let size = (hint as NSString).size(withAttributes: attrs)
      let hintRect = NSRect(x: rect.minX, y: rect.maxY + 8, width: size.width, height: size.height)
      (hint as NSString).draw(in: hintRect, withAttributes: attrs)
    }
  }

  private func currentSelectionRect() -> NSRect? {
    guard let start = dragStartPoint, let current = dragCurrentPoint else {
      return nil
    }
    return NSRect(
      x: min(start.x, current.x),
      y: min(start.y, current.y),
      width: abs(current.x - start.x),
      height: abs(current.y - start.y)
    )
  }
}
