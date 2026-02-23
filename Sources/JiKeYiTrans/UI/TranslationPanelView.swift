import Foundation
import MarkdownUI
import SwiftUI

enum ServiceRenderStatus: Sendable {
  case running
  case done
  case failed
}

struct ServiceRenderItem: Identifiable, Equatable, Sendable {
  var id: String
  var name: String
  var model: String
  var status: ServiceRenderStatus
  var content: String
  var detail: String?
  var thinking: String
  var isThinkingExpanded: Bool
  var isActive: Bool
  var explanation: String
  var explanationError: String?
  var isGeneratingExplanation: Bool
  var englishLearning: String
  var englishLearningError: String?
  var isGeneratingEnglishLearning: Bool
}

@MainActor
final class TranslationPanelViewModel: ObservableObject {
  private struct StreamAnimationTarget: Sendable {
    var text: String
    var thinking: String
    var explanation: String
    var englishLearning: String
  }

  @Published var sourceText: String = ""
  @Published var statusText: String = "待命"
  @Published var fontSize: Int = 16
  @Published var popupMode: PopupMode = .panel
  @Published var services: [ServiceRenderItem] = []
  @Published var globalMessage: String = ""
  @Published var automation: AutomationSettings = .defaults
  @Published var canReplaceSelection: Bool = false

  var onReplaceTranslationRequested: ((String, String) -> Void)?

  private var streamTargets: [String: StreamAnimationTarget] = [:]
  private var streamAnimatorTasks: [String: Task<Void, Never>] = [:]

  func estimatedWindowSize(for mode: PopupMode) -> CGSize {
    let width: CGFloat = mode == .panel ? 1080 : 760

    let sourceHeight = preferredSourceHeight(for: mode)
    let serviceHeight = preferredServiceListHeight(for: mode)
    let extraMessageHeight: CGFloat = globalMessage.isEmpty ? 0 : 52
    let baseChrome: CGFloat = mode == .panel ? 116 : 104

    let minHeight: CGFloat = mode == .panel ? 520 : 420
    let maxHeight: CGFloat = mode == .panel ? 1100 : 920

    let estimated = baseChrome + sourceHeight + serviceHeight + extraMessageHeight
    let height = clamp(estimated, min: minHeight, max: maxHeight)
    return CGSize(width: width, height: height)
  }

  func preferredSourceHeight(for mode: PopupMode) -> CGFloat {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = lineCount(text)
    let chars = text.count

    let lineFactor = CGFloat(fontSize + 3) * 0.74
    let value = 72 + CGFloat(min(lines, 14)) * lineFactor + CGFloat(min(chars, 1200)) * 0.028

    let maxHeight: CGFloat = mode == .panel ? 228 : 192
    return clamp(value, min: 92, max: maxHeight)
  }

  func shouldScrollSource(for _: PopupMode) -> Bool {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    return lineCount(text) > 6 || text.count > 260
  }

  func shouldUseScrollableServiceList(for mode: PopupMode) -> Bool {
    guard !services.isEmpty else {
      return false
    }
    let totalHeight = services
      .map(serviceCardEstimatedHeight)
      .reduce(0, +) + CGFloat(max(services.count - 1, 0)) * 10

    let containerBase = totalHeight + 56
    let noScrollLimit: CGFloat = mode == .panel ? 700 : 560
    return containerBase > noScrollLimit
  }

  func preferredServiceListHeight(for mode: PopupMode) -> CGFloat {
    guard !services.isEmpty else {
      return 180
    }

    let contentHeight = services
      .map(serviceCardEstimatedHeight)
      .reduce(0, +) + CGFloat(max(services.count - 1, 0)) * 10

    let containerBase = contentHeight + 56
    let noScrollLimit: CGFloat = mode == .panel ? 700 : 560
    return clamp(containerBase, min: 220, max: noScrollLimit)
  }

  func startTask(
    source: String,
    services: [ServiceConfig],
    activeServiceID: String,
    fontSize: Int,
    popupMode: PopupMode,
    thinkingDefaultExpanded: Bool,
    automation: AutomationSettings,
    canReplaceSelection: Bool
  ) {
    cancelStreamAnimations()
    sourceText = source
    statusText = "翻译中"
    self.fontSize = fontSize
    self.popupMode = popupMode
    self.automation = automation
    self.canReplaceSelection = canReplaceSelection
    globalMessage = ""

    self.services = services.map { service in
      ServiceRenderItem(
        id: service.id,
        name: service.name,
        model: service.model,
        status: .running,
        content: "",
        detail: nil,
        thinking: "",
        isThinkingExpanded: thinkingDefaultExpanded,
        isActive: service.id == activeServiceID,
        explanation: "",
        explanationError: nil,
        isGeneratingExplanation: false,
        englishLearning: "",
        englishLearningError: nil,
        isGeneratingEnglishLearning: false
      )
    }
  }

  func applySuccess(serviceID: String, text: String) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    updateService(serviceID: serviceID) { item in
      item.status = .done
      item.content = normalized
      item.detail = nil
    }
    if let item = serviceItem(for: serviceID) {
      var target = currentStreamTarget(for: serviceID, item: item)
      target.text = normalized
      target.thinking = item.thinking
      streamTargets[serviceID] = target
    }
    maybeStopStreamAnimationIfIdle(for: serviceID)
    refreshTaskStatus()
  }

  func applyStreaming(serviceID: String, text: String, thinking: String) {
    guard !text.isEmpty || !thinking.isEmpty else {
      return
    }

    guard let index = services.firstIndex(where: { $0.id == serviceID }) else {
      return
    }
    let item = services[index]
    var target = currentStreamTarget(for: serviceID, item: item)

    if !text.isEmpty {
      target.text = text
    }
    if !thinking.isEmpty {
      target.thinking = thinking
    }

    streamTargets[serviceID] = target
    beginStreamAnimationIfNeeded(for: serviceID)
  }

  func applyError(serviceID: String, message: String, detail: String?) {
    let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    updateService(serviceID: serviceID) { item in
      item.status = .failed
      item.content = normalizedMessage
      item.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let item = serviceItem(for: serviceID) {
      var target = currentStreamTarget(for: serviceID, item: item)
      target.text = normalizedMessage
      target.thinking = item.thinking
      streamTargets[serviceID] = target
    }
    maybeStopStreamAnimationIfIdle(for: serviceID)
    refreshTaskStatus()
  }

  func setExplanationLoading(serviceID: String, isLoading: Bool) {
    updateService(serviceID: serviceID) { item in
      item.isGeneratingExplanation = isLoading
      if isLoading {
        item.explanationError = nil
      }
    }
    maybeStopStreamAnimationIfIdle(for: serviceID)
  }

  func setEnglishLearningLoading(serviceID: String, isLoading: Bool) {
    updateService(serviceID: serviceID) { item in
      item.isGeneratingEnglishLearning = isLoading
      if isLoading {
        item.englishLearningError = nil
      }
    }
    maybeStopStreamAnimationIfIdle(for: serviceID)
  }

  func applyExplanationStreaming(serviceID: String, text: String) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return
    }

    guard let item = serviceItem(for: serviceID) else {
      return
    }

    var target = currentStreamTarget(for: serviceID, item: item)
    target.explanation = normalized
    streamTargets[serviceID] = target
    beginStreamAnimationIfNeeded(for: serviceID)
  }

  func applyEnglishLearningStreaming(serviceID: String, text: String) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return
    }

    guard let item = serviceItem(for: serviceID) else {
      return
    }

    var target = currentStreamTarget(for: serviceID, item: item)
    target.englishLearning = normalized
    streamTargets[serviceID] = target
    beginStreamAnimationIfNeeded(for: serviceID)
  }

  func applyExplanation(serviceID: String, text: String?, error: String?) {
    let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedError = error?.trimmingCharacters(in: .whitespacesAndNewlines)

    if !normalizedText.isEmpty {
      applyExplanationStreaming(serviceID: serviceID, text: normalizedText)
    }

    updateService(serviceID: serviceID) { item in
      item.isGeneratingExplanation = false
      if normalizedText.isEmpty, normalizedError == nil {
        item.explanation = ""
      }
      item.explanationError = normalizedError
    }
    maybeStopStreamAnimationIfIdle(for: serviceID)
  }

  func applyEnglishLearning(serviceID: String, text: String?, error: String?) {
    let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedError = error?.trimmingCharacters(in: .whitespacesAndNewlines)

    if !normalizedText.isEmpty {
      applyEnglishLearningStreaming(serviceID: serviceID, text: normalizedText)
    }

    updateService(serviceID: serviceID) { item in
      item.isGeneratingEnglishLearning = false
      if normalizedText.isEmpty, normalizedError == nil {
        item.englishLearning = ""
      }
      item.englishLearningError = normalizedError
    }
    maybeStopStreamAnimationIfIdle(for: serviceID)
  }

  func finishTask() {
    refreshTaskStatus(forceComplete: true)
  }

  func showFatalError(
    source: String,
    message: String,
    fontSize: Int,
    popupMode: PopupMode
  ) {
    cancelStreamAnimations()
    sourceText = source
    statusText = "失败"
    self.fontSize = fontSize
    self.popupMode = popupMode
    services = []
    globalMessage = message
  }

  func copyHighlightedWordIfNeeded(from text: String) {
    guard automation.copyHighlightedWordOnClick else {
      return
    }

    guard let word = firstEnglishWord(in: text) else {
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(word, forType: .string)
    globalMessage = "已复制单词：\(word)"
  }

  func setGlobalMessage(_ message: String) {
    globalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func canReplaceTranslation(for item: ServiceRenderItem) -> Bool {
    guard canReplaceSelection, item.status == .done else {
      return false
    }
    return !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func requestReplaceTranslation(serviceID: String) {
    guard canReplaceSelection else {
      globalMessage = "仅“选中文本翻译”支持替换原文。"
      return
    }

    guard let item = serviceItem(for: serviceID) else {
      return
    }

    let translated = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard item.status == .done, !translated.isEmpty else {
      globalMessage = "该服务译文还未完成，暂时无法替换。"
      return
    }

    onReplaceTranslationRequested?(serviceID, translated)
  }

  private func updateService(serviceID: String, mutate: (inout ServiceRenderItem) -> Void) {
    guard let index = services.firstIndex(where: { $0.id == serviceID }) else {
      return
    }
    var item = services[index]
    mutate(&item)
    services[index] = item
  }

  private func serviceItem(for serviceID: String) -> ServiceRenderItem? {
    services.first(where: { $0.id == serviceID })
  }

  private func currentStreamTarget(for serviceID: String, item: ServiceRenderItem) -> StreamAnimationTarget {
    streamTargets[serviceID] ?? StreamAnimationTarget(
      text: item.content,
      thinking: item.thinking,
      explanation: item.explanation,
      englishLearning: item.englishLearning
    )
  }

  private func shouldKeepStreamAnimationAlive(for item: ServiceRenderItem) -> Bool {
    item.status == .running || item.isGeneratingExplanation || item.isGeneratingEnglishLearning
  }

  private func maybeStopStreamAnimationIfIdle(for serviceID: String) {
    guard let item = serviceItem(for: serviceID),
          let target = streamTargets[serviceID]
    else {
      return
    }

    let hasPendingDelta = item.content != target.text
      || item.thinking != target.thinking
      || item.explanation != target.explanation
      || item.englishLearning != target.englishLearning

    if !hasPendingDelta, !shouldKeepStreamAnimationAlive(for: item) {
      stopStreamAnimation(for: serviceID)
    }
  }

  private func refreshTaskStatus(forceComplete: Bool = false) {
    guard !services.isEmpty else {
      return
    }

    let running = services.filter { $0.status == .running }.count
    let failed = services.filter { $0.status == .failed }.count

    if running > 0 && !forceComplete {
      statusText = "翻译中（\(services.count - running)/\(services.count)）"
      return
    }

    if failed == 0 {
      statusText = "完成（\(services.count)/\(services.count)）"
    } else if failed == services.count {
      statusText = "失败"
    } else {
      statusText = "部分失败（\(services.count - failed)/\(services.count)）"
    }
  }

  private func serviceCardEstimatedHeight(for item: ServiceRenderItem) -> CGFloat {
    let header: CGFloat = item.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 54 : 70
    let thinkingBlock = thinkingBlockEstimatedHeight(item.thinking, isExpanded: item.isThinkingExpanded)
    let explanationBlock = supplementBlockEstimatedHeight(
      title: "原文讲解",
      content: item.explanation,
      error: item.explanationError,
      isLoading: item.isGeneratingExplanation
    )
    let learningBlock = supplementBlockEstimatedHeight(
      title: "英语学习",
      content: item.englishLearning,
      error: item.englishLearningError,
      isLoading: item.isGeneratingEnglishLearning
    )
    let supplementBlock = explanationBlock + learningBlock

    switch item.status {
    case .running:
      if item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return header + 42 + thinkingBlock + supplementBlock
      }
      let lines = CGFloat(estimatedVisualLineCount(item.content, charsPerLine: estimatedCharsPerLineForMainText()))
      let lineHeight = CGFloat(fontSize + 6)
      let body = max(30, lines * lineHeight)
      return header + max(42, body) + thinkingBlock + supplementBlock
    case .done, .failed:
      let lines = CGFloat(estimatedVisualLineCount(item.content, charsPerLine: estimatedCharsPerLineForMainText()))
      let lineHeight = CGFloat(fontSize + 6)
      var body = max(30, lines * lineHeight)
      body += thinkingBlock
      body += supplementBlock
      if item.status == .failed, let detail = item.detail, !detail.isEmpty {
        let detailLines = CGFloat(estimatedVisualLineCount(detail, charsPerLine: estimatedCharsPerLineForDetailText()))
        body += max(24, detailLines * 12) + 10
      }
      return header + body
    }
  }

  private func firstEnglishWord(in text: String) -> String? {
    let range = NSRange(location: 0, length: text.utf16.count)
    guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z'-]*"#) else {
      return nil
    }
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      return nil
    }
    guard let swiftRange = Range(match.range, in: text) else {
      return nil
    }
    return String(text[swiftRange])
  }

  private func lineCount(_ text: String) -> Int {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return 1
    }
    return max(1, value.split(whereSeparator: \.isNewline).count)
  }

  private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, lower), upper)
  }

  private func beginStreamAnimationIfNeeded(for serviceID: String) {
    if streamAnimatorTasks[serviceID] != nil {
      return
    }

    streamAnimatorTasks[serviceID] = Task { [weak self] in
      await self?.runStreamAnimation(for: serviceID)
    }
  }

  private func runStreamAnimation(for serviceID: String) async {
    defer {
      streamAnimatorTasks[serviceID] = nil
    }

    while !Task.isCancelled {
      guard let target = streamTargets[serviceID] else {
        return
      }

      guard let index = services.firstIndex(where: { $0.id == serviceID }) else {
        return
      }

      let item = services[index]
      let noPendingDelta = item.content == target.text
        && item.thinking == target.thinking
        && item.explanation == target.explanation
        && item.englishLearning == target.englishLearning

      if noPendingDelta {
        if !shouldKeepStreamAnimationAlive(for: item) {
          streamTargets.removeValue(forKey: serviceID)
          return
        }
        try? await Task.sleep(nanoseconds: 18_000_000)
        continue
      }

      let nextText = nextTypewriterText(current: item.content, target: target.text)
      let nextThinking = nextTypewriterText(current: item.thinking, target: target.thinking)
      let nextExplanation = nextTypewriterText(current: item.explanation, target: target.explanation)
      let nextLearning = nextTypewriterText(current: item.englishLearning, target: target.englishLearning)

      if nextText == item.content,
         nextThinking == item.thinking,
         nextExplanation == item.explanation,
         nextLearning == item.englishLearning
      {
        try? await Task.sleep(nanoseconds: 14_000_000)
        continue
      }

      var updated = item
      updated.content = nextText
      updated.thinking = nextThinking
      updated.explanation = nextExplanation
      updated.englishLearning = nextLearning
      if nextText != item.content || nextThinking != item.thinking {
        updated.detail = nil
      }
      services[index] = updated

      let textDelta = max(nextText.count - item.content.count, 0)
      let thinkingDelta = max(nextThinking.count - item.thinking.count, 0)
      let explanationDelta = max(nextExplanation.count - item.explanation.count, 0)
      let learningDelta = max(nextLearning.count - item.englishLearning.count, 0)
      let appendedCount = max(1, textDelta + thinkingDelta + explanationDelta + learningDelta)
      let delay = animationDelay(for: appendedCount)
      try? await Task.sleep(nanoseconds: delay)
    }
  }

  private func nextTypewriterText(current: String, target: String) -> String {
    guard target.hasPrefix(current) else {
      return target
    }

    let remaining = target.count - current.count
    guard remaining > 0 else {
      return current
    }

    let step: Int
    switch remaining {
    case 1 ... 24:
      step = 1
    case 25 ... 80:
      step = 2
    case 81 ... 200:
      step = 3
    default:
      step = 4
    }

    let nextCount = min(target.count, current.count + step)
    let end = target.index(target.startIndex, offsetBy: nextCount)
    return String(target[..<end])
  }

  private func animationDelay(for appendedCount: Int) -> UInt64 {
    let baseMs: UInt64 = 16
    let discount = UInt64(min(appendedCount - 1, 5))
    let ms = max(8, Int(baseMs) - Int(discount))
    return UInt64(ms) * 1_000_000
  }

  private func stopStreamAnimation(for serviceID: String) {
    streamTargets.removeValue(forKey: serviceID)
    streamAnimatorTasks[serviceID]?.cancel()
    streamAnimatorTasks.removeValue(forKey: serviceID)
  }

  private func cancelStreamAnimations() {
    streamTargets.removeAll(keepingCapacity: false)
    for task in streamAnimatorTasks.values {
      task.cancel()
    }
    streamAnimatorTasks.removeAll(keepingCapacity: false)
  }

  func setThinkingExpanded(serviceID: String, isExpanded: Bool) {
    updateService(serviceID: serviceID) { item in
      item.isThinkingExpanded = isExpanded
    }
  }

  private func thinkingBlockEstimatedHeight(_ thinking: String, isExpanded: Bool) -> CGFloat {
    let text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return 0
    }
    guard isExpanded else {
      return 32
    }
    let lines = CGFloat(estimatedVisualLineCount(text, charsPerLine: estimatedCharsPerLineForDetailText()))
    return 36 + max(18, lines * 12)
  }

  private func supplementBlockEstimatedHeight(
    title _: String,
    content: String,
    error: String?,
    isLoading: Bool
  ) -> CGFloat {
    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let err = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard isLoading || !text.isEmpty || !err.isEmpty else {
      return 0
    }

    var height: CGFloat = 38
    if isLoading, text.isEmpty, err.isEmpty {
      return height
    }

    if !text.isEmpty {
      let lines = CGFloat(estimatedVisualLineCount(text, charsPerLine: estimatedCharsPerLineForDetailText()))
      height += max(20, lines * 12) + 8
    }

    if !err.isEmpty {
      let lines = CGFloat(estimatedVisualLineCount(err, charsPerLine: estimatedCharsPerLineForDetailText()))
      height += max(20, lines * 12) + 8
    }

    return height
  }

  private func estimatedVisualLineCount(_ text: String, charsPerLine: Int) -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return 1
    }

    let width = max(12, charsPerLine)
    var total = 0
    for paragraph in trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let length = max(1, paragraph.count)
      let wrapped = Int(ceil(Double(length) / Double(width)))
      total += max(1, wrapped)
    }
    return max(1, total)
  }

  private func estimatedCharsPerLineForMainText() -> Int {
    switch popupMode {
    case .panel:
      return 56
    case .bubble:
      return 38
    }
  }

  private func estimatedCharsPerLineForDetailText() -> Int {
    switch popupMode {
    case .panel:
      return 62
    case .bubble:
      return 44
    }
  }
}

struct TranslationPanelView: View {
  @ObservedObject var model: TranslationPanelViewModel

  private let background = LinearGradient(
    colors: [
      Color(red: 0.05, green: 0.11, blue: 0.16),
      Color(red: 0.08, green: 0.15, blue: 0.22),
      Color(red: 0.12, green: 0.10, blue: 0.16)
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  var body: some View {
    ZStack {
      background.ignoresSafeArea()

      VStack(spacing: 10) {
        headerBar

        sourceCard
          .frame(height: model.preferredSourceHeight(for: model.popupMode), alignment: .top)
          .padding(.bottom, 6)

        serviceListCard
          .frame(height: model.preferredServiceListHeight(for: model.popupMode), alignment: .top)

        if !model.globalMessage.isEmpty {
          globalMessageCard(text: model.globalMessage)
        }
      }
      .padding(12)
      .animation(.easeInOut(duration: 0.2), value: model.popupMode)
    }
  }

  private var headerBar: some View {
    HStack(spacing: 10) {
      Text("即刻译")
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundStyle(.white)

      statusPill(text: model.statusText)

      Spacer()

      Text(model.popupMode == .bubble ? "Bubble" : "Panel")
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
    }
  }

  private var sourceCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("原文")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
        Spacer()
        Text("\(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).count) 字")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.65))
      }

      if model.shouldScrollSource(for: model.popupMode) {
        ScrollView {
          sourceTextView
        }
      } else {
        sourceTextView
      }
    }
    .padding(10)
    .background(cardBackground)
    .overlay(cardBorder)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .clipped()
  }

  private var sourceTextView: some View {
    Text(model.sourceText.isEmpty ? "等待选中文本" : model.sourceText)
      .font(.system(size: CGFloat(model.fontSize), weight: .regular, design: .rounded))
      .foregroundStyle(Color.white.opacity(0.92))
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var serviceListCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("多服务译文")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
        Spacer()
        Text("\(model.services.count) 个服务")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.65))
      }

      if model.services.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Text("暂无服务结果")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
          Text("请检查服务配置，或重新触发翻译。")
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ScrollView {
          serviceCards
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .padding(10)
    .background(cardBackground)
    .overlay(cardBorder)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var serviceCards: some View {
    VStack(spacing: 10) {
      ForEach(Array(model.services.enumerated()), id: \.element.id) { index, item in
        serviceCard(item, index: index)
      }
    }
  }

  private func serviceCard(_ item: ServiceRenderItem, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center) {
        Text(item.name)
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(.white)

        if item.isActive {
          Text("当前")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.97, green: 0.92, blue: 0.74))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(red: 0.45, green: 0.34, blue: 0.12).opacity(0.62))
            .clipShape(Capsule())
        }

        Spacer()

        if model.canReplaceSelection {
          replaceButton(item: item, index: index)
        }

        statusTag(for: item.status)
      }

      if !item.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(item.model)
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.66))
      }

      Group {
        switch item.status {
        case .running:
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
                .tint(Color.white.opacity(0.85))
              Text(item.content.isEmpty ? (item.thinking.isEmpty ? "等待结果..." : "思考中...") : "生成译文中...")
            }

            if !item.content.isEmpty {
              Text(item.content)
                .textSelection(.enabled)
            }

            if !item.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              thinkingSection(
                item.thinking,
                isExpanded: thinkingExpandedBinding(for: item.id)
              )
            }

            supplementBlocks(item)
          }
        case .done:
          VStack(alignment: .leading, spacing: 6) {
            Text(item.content)
              .textSelection(.enabled)
              .onTapGesture {
                model.copyHighlightedWordIfNeeded(from: item.content)
              }

            if !item.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              thinkingSection(
                item.thinking,
                isExpanded: thinkingExpandedBinding(for: item.id)
              )
            }

            supplementBlocks(item)
          }
        case .failed:
          VStack(alignment: .leading, spacing: 6) {
            Text(item.content)
              .foregroundStyle(Color(red: 1.0, green: 0.70, blue: 0.70))

            if !item.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              thinkingSection(
                item.thinking,
                isExpanded: thinkingExpandedBinding(for: item.id)
              )
            }

            supplementBlocks(item)

            if let detail = item.detail, !detail.isEmpty {
              Text("接口返回：\(detail)")
                .font(.system(size: max(10, CGFloat(model.fontSize) - 3), weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.68))
                .textSelection(.enabled)
            }
          }
        }
      }
      .font(.system(size: CGFloat(model.fontSize), weight: .regular, design: .rounded))
      .foregroundStyle(Color.white.opacity(0.90))
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(9)
    .background(Color.white.opacity(0.07))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(Color.white.opacity(0.09), lineWidth: 0.8)
    )
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
  }

  private func replaceButton(item: ServiceRenderItem, index: Int) -> some View {
    let shortcutNumber = index + 1
    let canShowShortcut = shortcutNumber <= 9

    return Button {
      model.requestReplaceTranslation(serviceID: item.id)
    } label: {
      HStack(spacing: 4) {
        Text("替换")
        if canShowShortcut {
          Text("⌥\(shortcutNumber)")
            .foregroundStyle(Color.white.opacity(0.70))
        }
      }
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.white.opacity(0.10))
      .overlay(
        Capsule()
          .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
      )
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .opacity(model.canReplaceTranslation(for: item) ? 1 : 0.42)
    .disabled(!model.canReplaceTranslation(for: item))
    .help(canShowShortcut ? "替换为该服务译文（快捷键：Alt+\(shortcutNumber)）" : "替换为该服务译文")
  }

  private func thinkingSection(_ text: String, isExpanded: Binding<Bool>) -> some View {
    DisclosureGroup(isExpanded: isExpanded) {
      Text(text)
        .font(.system(size: max(10, CGFloat(model.fontSize) - 3), weight: .regular, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.70))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    } label: {
      Text("思考过程")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.72))
    }
    .padding(7)
    .background(Color.white.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func supplementBlocks(_ item: ServiceRenderItem) -> some View {
    if item.isGeneratingExplanation || !item.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (item.explanationError?.isEmpty == false) {
      supplementSection(
        title: "原文讲解",
        text: item.explanation,
        error: item.explanationError,
        isLoading: item.isGeneratingExplanation,
        accent: Color(red: 0.30, green: 0.58, blue: 0.90).opacity(0.30)
      )
    }

    if item.isGeneratingEnglishLearning || !item.englishLearning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (item.englishLearningError?.isEmpty == false) {
      supplementSection(
        title: "英语学习",
        text: item.englishLearning,
        error: item.englishLearningError,
        isLoading: item.isGeneratingEnglishLearning,
        accent: Color(red: 0.24, green: 0.62, blue: 0.44).opacity(0.30)
      )
    }
  }

  private func supplementSection(
    title: String,
    text: String,
    error: String?,
    isLoading: Bool,
    accent: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Text(title)
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.86))
        Spacer()
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(Color.white.opacity(0.82))
        }
      }

      if isLoading, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (error?.isEmpty ?? true) {
        Text("生成中...")
          .font(.system(size: max(10, CGFloat(model.fontSize) - 3), weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.72))
      }

      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        markdownSupplementText(
          text,
          fontSize: max(10, CGFloat(model.fontSize) - 2),
          color: Color.white.opacity(0.90)
        )
      }

      if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(error)
          .font(.system(size: max(10, CGFloat(model.fontSize) - 3), weight: .regular, design: .monospaced))
          .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.74))
          .textSelection(.enabled)
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.white.opacity(0.04))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(accent, lineWidth: 0.8)
        )
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func markdownSupplementText(_ text: String, fontSize: CGFloat, color: Color) -> some View {
    let normalized = normalizeSupplementMarkdownText(text)
    if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      EmptyView()
    } else {
      Markdown(normalized)
        .markdownTheme(.basic)
        .markdownTextStyle {
          FontSize(fontSize)
          ForegroundColor(color)
          BackgroundColor(nil)
        }
        .markdownTextStyle(\.strong) {
          FontWeight(.semibold)
          ForegroundColor(color.opacity(0.98))
          BackgroundColor(nil)
        }
        .markdownTextStyle(\.link) {
          ForegroundColor(Color(red: 0.58, green: 0.78, blue: 1.0))
        }
        .markdownTextStyle(\.code) {
          FontFamilyVariant(.monospaced)
          FontSize(max(10, fontSize - 1))
          ForegroundColor(Color.white.opacity(0.94))
          BackgroundColor(Color.white.opacity(0.10))
        }
        .markdownBlockStyle(\.heading1) { configuration in
          configuration.label
            .markdownTextStyle {
              FontWeight(.semibold)
              FontSize(.em(1.35))
              ForegroundColor(color.opacity(0.98))
            }
            .markdownMargin(top: 4, bottom: 8)
        }
        .markdownBlockStyle(\.heading2) { configuration in
          configuration.label
            .markdownTextStyle {
              FontWeight(.semibold)
              FontSize(.em(1.25))
              ForegroundColor(color.opacity(0.98))
            }
            .markdownMargin(top: 6, bottom: 8)
        }
        .markdownBlockStyle(\.heading3) { configuration in
          configuration.label
            .markdownTextStyle {
              FontWeight(.semibold)
              FontSize(.em(1.13))
              ForegroundColor(color.opacity(0.96))
            }
            .markdownMargin(top: 6, bottom: 6)
        }
        .markdownBlockStyle(\.paragraph) { configuration in
          configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.20))
            .markdownMargin(top: 0, bottom: 10)
        }
        .markdownBlockStyle(\.blockquote) { configuration in
          HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(Color.white.opacity(0.20))
              .frame(width: 3)
            configuration.label
              .padding(.leading, 10)
              .padding(.trailing, 8)
              .padding(.vertical, 4)
          }
          .background(Color.white.opacity(0.045))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .markdownMargin(top: 0, bottom: 10)
        }
        .markdownBlockStyle(\.codeBlock) { configuration in
          ScrollView(.horizontal) {
            configuration.label
              .fixedSize(horizontal: false, vertical: true)
              .relativeLineSpacing(.em(0.16))
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
          }
          .background(Color.white.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
          )
          .markdownMargin(top: 0, bottom: 10)
        }
        .markdownBlockStyle(\.table) { configuration in
          configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTableBorderStyle(
              TableBorderStyle(.allBorders, color: Color.white.opacity(0.14), width: 0.7)
            )
            .markdownTableBackgroundStyle(
              .alternatingRows(
                Color.white.opacity(0.06),
                Color.white.opacity(0.03),
                header: Color.white.opacity(0.10)
              )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
            )
            .markdownMargin(top: 0, bottom: 10)
        }
        .markdownBlockStyle(\.tableCell) { configuration in
          configuration.label
            .markdownTextStyle {
              if configuration.row == 0 {
                FontWeight(.semibold)
                ForegroundColor(color.opacity(0.98))
              }
              BackgroundColor(nil)
            }
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.18))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func normalizeSupplementMarkdownText(_ text: String) -> String {
    var normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    normalized = normalized
      .replacingOccurrences(of: "```markdown\n", with: "```\n")
      .replacingOccurrences(of: "```md\n", with: "```\n")

    if normalized.contains("\\n") {
      normalized = normalized
        .replacingOccurrences(of: "\\r\\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\r", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
    }

    return normalized
  }

  private func thinkingExpandedBinding(for serviceID: String) -> Binding<Bool> {
    Binding(
      get: {
        model.services.first(where: { $0.id == serviceID })?.isThinkingExpanded ?? false
      },
      set: { next in
        model.setThinkingExpanded(serviceID: serviceID, isExpanded: next)
      }
    )
  }

  private func statusTag(for status: ServiceRenderStatus) -> some View {
    let text: String
    let background: Color
    switch status {
    case .running:
      text = "处理中"
      background = Color(red: 0.20, green: 0.42, blue: 0.62).opacity(0.65)
    case .done:
      text = "完成"
      background = Color(red: 0.20, green: 0.50, blue: 0.34).opacity(0.7)
    case .failed:
      text = "失败"
      background = Color(red: 0.56, green: 0.19, blue: 0.19).opacity(0.75)
    }

    return Text(text)
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background)
      .clipShape(Capsule())
  }

  private func statusPill(text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 3)
      .background(Color.white.opacity(0.16))
      .clipShape(Capsule())
  }

  private func globalMessageCard(text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text("提示")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(Color(red: 0.96, green: 0.88, blue: 0.72))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(red: 0.45, green: 0.31, blue: 0.10).opacity(0.72))
        .clipShape(Capsule())

      Text(text)
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(9)
    .background(Color.white.opacity(0.10))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
    )
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(Color.white.opacity(0.055))
  }

  private var cardBorder: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
  }
}
