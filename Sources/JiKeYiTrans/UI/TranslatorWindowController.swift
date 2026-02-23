import AppKit
import SwiftUI

@MainActor
final class TranslatorWindowController: NSWindowController, NSWindowDelegate {
  private let viewModel = TranslationPanelViewModel()
  private var currentMode: PopupMode = .panel
  private var lastAnchor: CGRect?
  private var lastStreamingResizeUptime: TimeInterval = 0
  var onBubbleDismiss: (() -> Void)?
  var onWindowHidden: (() -> Void)?
  var onReplaceTranslationRequested: ((String, String) -> Void)?

  private var globalClickMonitor: Any?
  private var localClickMonitor: Any?
  private var localKeyMonitor: Any?

  init() {
    let hosting = NSHostingController(rootView: TranslationPanelView(model: viewModel))
    let window = NSWindow(contentViewController: hosting)
    window.title = "即刻译"
    window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.minSize = NSSize(width: 520, height: 360)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true

    super.init(window: window)
    window.delegate = self
    viewModel.onReplaceTranslationRequested = { [weak self] serviceID, text in
      self?.onReplaceTranslationRequested?(serviceID, text)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func showLoading(
    source: String,
    services: [ServiceConfig],
    activeServiceID: String,
    fontSize: Int,
    popupMode: PopupMode,
    thinkingDefaultExpanded: Bool,
    automation: AutomationSettings,
    canReplaceSelection: Bool,
    anchor: CGRect?
  ) {
    viewModel.startTask(
      source: source,
      services: services,
      activeServiceID: activeServiceID,
      fontSize: fontSize,
      popupMode: popupMode,
      thinkingDefaultExpanded: thinkingDefaultExpanded,
      automation: automation,
      canReplaceSelection: canReplaceSelection
    )

    present(mode: popupMode, anchor: anchor)
  }

  func showFatalError(
    source: String,
    message: String,
    fontSize: Int,
    popupMode: PopupMode,
    anchor: CGRect?
  ) {
    viewModel.showFatalError(source: source, message: message, fontSize: fontSize, popupMode: popupMode)
    present(mode: popupMode, anchor: anchor)
  }

  func updateServiceResult(serviceID: String, result: String) {
    viewModel.applySuccess(serviceID: serviceID, text: result)
    adaptWindowSize(allowShrink: true, positionUsingAnchor: false)
  }

  func updateServiceStreaming(serviceID: String, text: String, thinking: String) {
    viewModel.applyStreaming(serviceID: serviceID, text: text, thinking: thinking)
    throttledStreamingResize()
  }

  func updateServiceExplanationStreaming(serviceID: String, text: String) {
    viewModel.applyExplanationStreaming(serviceID: serviceID, text: text)
    throttledStreamingResize()
  }

  func updateServiceLearningStreaming(serviceID: String, text: String) {
    viewModel.applyEnglishLearningStreaming(serviceID: serviceID, text: text)
    throttledStreamingResize()
  }

  func updateServiceError(serviceID: String, message: String, detail: String?) {
    viewModel.applyError(serviceID: serviceID, message: message, detail: detail)
    adaptWindowSize(allowShrink: true, positionUsingAnchor: false)
  }

  func setServiceExplanationLoading(serviceID: String, isLoading: Bool) {
    viewModel.setExplanationLoading(serviceID: serviceID, isLoading: isLoading)
    adaptWindowSize(allowShrink: false, positionUsingAnchor: false)
  }

  func setServiceLearningLoading(serviceID: String, isLoading: Bool) {
    viewModel.setEnglishLearningLoading(serviceID: serviceID, isLoading: isLoading)
    adaptWindowSize(allowShrink: false, positionUsingAnchor: false)
  }

  func updateServiceExplanation(serviceID: String, text: String?, error: String?) {
    viewModel.applyExplanation(serviceID: serviceID, text: text, error: error)
    adaptWindowSize(allowShrink: true, positionUsingAnchor: false)
  }

  func updateServiceLearning(serviceID: String, text: String?, error: String?) {
    viewModel.applyEnglishLearning(serviceID: serviceID, text: text, error: error)
    adaptWindowSize(allowShrink: true, positionUsingAnchor: false)
  }

  func finishCurrentTask() {
    viewModel.finishTask()
    adaptWindowSize(allowShrink: true, positionUsingAnchor: false)
  }

  func setGlobalMessage(_ message: String) {
    viewModel.setGlobalMessage(message)
    adaptWindowSize(allowShrink: true, positionUsingAnchor: false)
  }

  private func throttledStreamingResize() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastStreamingResizeUptime > 0.12 {
      lastStreamingResizeUptime = now
      adaptWindowSize(allowShrink: false, positionUsingAnchor: false)
    }
  }

  private func present(mode: PopupMode, anchor: CGRect?) {
    currentMode = mode
    lastAnchor = anchor
    updateWindowSizeLimits(for: mode)
    adaptWindowSize(allowShrink: true, positionUsingAnchor: true)

    guard let window else {
      return
    }

    if mode == .bubble {
      window.level = .statusBar
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.makeKeyAndOrderFront(nil)
      startBubbleDismissMonitoring()
    } else {
      window.level = .floating
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      stopBubbleDismissMonitoring()
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func updateWindowSizeLimits(for mode: PopupMode) {
    guard let window else {
      return
    }

    let metrics = modeMetrics(mode)
    switch mode {
    case .panel:
      window.minSize = NSSize(width: metrics.width, height: metrics.minHeight)
      window.maxSize = NSSize(width: metrics.width, height: metrics.maxHeight)
    case .bubble:
      window.minSize = NSSize(width: metrics.width, height: metrics.minHeight)
      window.maxSize = NSSize(width: metrics.width, height: metrics.maxHeight)
    }
  }

  private func adaptWindowSize(allowShrink: Bool, positionUsingAnchor: Bool) {
    guard let window else {
      return
    }

    let estimated = viewModel.estimatedWindowSize(for: currentMode)
    let metrics = modeMetrics(currentMode)
    let current = window.frame.size

    let targetWidth = metrics.width
    var targetHeight = max(metrics.minHeight, estimated.height)
    targetHeight = min(targetHeight, metrics.maxHeight)

    if !allowShrink {
      targetHeight = max(targetHeight, current.height)
    }

    let targetSize = NSSize(width: targetWidth, height: targetHeight)
    if abs(current.width - targetSize.width) < 1, abs(current.height - targetSize.height) < 1 {
      if positionUsingAnchor {
        positionWindow(anchor: lastAnchor)
      }
      return
    }

    if positionUsingAnchor {
      window.setContentSize(targetSize)
      positionWindow(anchor: lastAnchor)
      return
    }

    let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
    window.setContentSize(targetSize)
    var frame = window.frame
    frame.origin.x = center.x - frame.width / 2
    frame.origin.y = center.y - frame.height / 2
    frame = clampFrameToVisible(frame)
    window.setFrame(frame, display: true, animate: true)
  }

  private func positionWindow(anchor: CGRect?) {
    guard let window else {
      return
    }

    let targetPoint = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation

    let screen = NSScreen.screens.first(where: { $0.frame.contains(targetPoint) })
      ?? NSScreen.main
      ?? NSScreen.screens.first

    guard let screen else {
      return
    }

    let visible = screen.visibleFrame
    let currentFrame = window.frame
    let margin: CGFloat = 12

    let x = min(
      max(targetPoint.x - currentFrame.width / 2, visible.minX + margin),
      visible.maxX - currentFrame.width - margin
    )

    var y = targetPoint.y - currentFrame.height - 20
    if y < visible.minY + margin {
      y = min(targetPoint.y + 20, visible.maxY - currentFrame.height - margin)
    }

    var nextFrame = window.frame
    nextFrame.origin = CGPoint(x: x, y: y)
    window.setFrame(clampFrameToVisible(nextFrame), display: true)
  }

  private func clampFrameToVisible(_ frame: NSRect) -> NSRect {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
      ?? NSScreen.main
      ?? NSScreen.screens.first

    guard let screen else {
      return frame
    }

    let visible = screen.visibleFrame
    let margin: CGFloat = 10
    var next = frame
    next.origin.x = min(
      max(next.origin.x, visible.minX + margin),
      visible.maxX - next.width - margin
    )
    next.origin.y = min(
      max(next.origin.y, visible.minY + margin),
      visible.maxY - next.height - margin
    )
    return next
  }

  private func modeMetrics(_ mode: PopupMode) -> (width: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) {
    switch mode {
    case .panel:
      return (width: 1080, minHeight: 520, maxHeight: 1100)
    case .bubble:
      return (width: 760, minHeight: 420, maxHeight: 920)
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if currentMode == .bubble {
      hideBubbleWindow()
      return false
    }

    stopBubbleDismissMonitoring()
    sender.orderOut(nil)
    onWindowHidden?()
    return false
  }

  func windowDidResignKey(_ notification: Notification) {
    if currentMode == .bubble {
      hideBubbleWindow()
    }
  }

  private func startBubbleDismissMonitoring() {
    stopBubbleDismissMonitoring()

    globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      Task { @MainActor in
        self?.handleGlobalClick(event)
      }
    }

    localClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self else {
        return event
      }
      self.handleLocalClick(event)
      return event
    }

    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self else {
        return event
      }

      if self.currentMode == .bubble, event.keyCode == 53 {
        self.hideBubbleWindow()
        return nil
      }

      return event
    }
  }

  private func stopBubbleDismissMonitoring() {
    if let globalClickMonitor {
      NSEvent.removeMonitor(globalClickMonitor)
      self.globalClickMonitor = nil
    }

    if let localClickMonitor {
      NSEvent.removeMonitor(localClickMonitor)
      self.localClickMonitor = nil
    }

    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
  }

  private func handleGlobalClick(_ event: NSEvent) {
    guard currentMode == .bubble,
          let window,
          window.isVisible
    else {
      return
    }

    let clickPoint = event.locationInWindow
    if !window.frame.contains(clickPoint) {
      hideBubbleWindow()
    }
  }

  private func handleLocalClick(_ event: NSEvent) {
    guard currentMode == .bubble,
          let window,
          window.isVisible
    else {
      return
    }

    if event.window !== window {
      hideBubbleWindow()
    }
  }

  private func hideBubbleWindow() {
    guard currentMode == .bubble, let window, window.isVisible else {
      return
    }

    stopBubbleDismissMonitoring()
    window.orderOut(nil)
    onBubbleDismiss?()
    onWindowHidden?()
  }
}
