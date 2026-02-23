import AppKit
import Foundation

@MainActor
final class AppController: NSObject {
  private enum TranslateSource {
    case selection
    case ocr
  }

  private enum SupplementKind: Sendable {
    case explanation
    case englishLearning
  }

  private struct ServiceTranslationOutcome: Sendable {
    let serviceID: String
    let translatedText: String?
    let errorMessage: String?
    let errorDetail: String?
  }

  private struct ServiceSupplementOutcome: Sendable {
    let serviceID: String
    let kind: SupplementKind
    let text: String?
    let errorMessage: String?
  }

  private enum StreamSection: Sendable {
    case translation
    case explanation
    case englishLearning
  }

  private struct ServiceStreamingUpdate: Sendable {
    let serviceID: String
    let section: StreamSection
    let partialText: String
    let partialThinking: String
  }

  private static let defaultHotKeySignature: OSType = 0x4A4B5954 // JKYT
  private static let replaceHotKeySignature: OSType = 0x4A4B5952 // JKYR

  private let settingsStore = SettingsStore()
  private let hotKeyManager = GlobalHotKeyManager(signature: AppController.defaultHotKeySignature)
  private let replaceHotKeyManager = GlobalHotKeyManager(signature: AppController.replaceHotKeySignature)
  private let translatorWindowController = TranslatorWindowController()
  private let translatorClient = TranslatorClient()
  private let selectionReader = SelectionReader()
  private let copyFallbackReader = CopyFallbackReader()
  private let selectionReplacementWriter = SelectionReplacementWriter()
  private let ocrReader = OCRReader()
  private let speechSynthesizer = NSSpeechSynthesizer()

  private var preferencesWindowController: PreferencesWindowController?
  private var statusItem: NSStatusItem?
  private var settings: AppSettings = .default
  private var isTranslating = false
  private var activeTranslationTask: Task<Void, Never>?
  private var translationStartedAt: Date?
  private var workspaceObservers: [NSObjectProtocol] = []

  private var translateHotKeyRegistered = false
  private var ocrHotKeyRegistered = false
  private var openSettingsHotKeyRegistered = false
  private var replaceShortcutServiceIDs: [String] = []
  private var replaceShortcutServiceNames: [String: String] = [:]
  private var replaceableTranslationsByServiceID: [String: String] = [:]
  private var canReplaceCurrentSelection = false
  private var replacementTargetProcessIdentifier: pid_t?

  func start() {
    translatorWindowController.onBubbleDismiss = { [weak self] in
      Task { @MainActor in
        self?.cancelTranslationAfterBubbleDismiss()
      }
    }
    translatorWindowController.onWindowHidden = { [weak self] in
      Task { @MainActor in
        self?.clearReplacementContext()
      }
    }
    translatorWindowController.onReplaceTranslationRequested = { [weak self] serviceID, text in
      Task { @MainActor in
        self?.replaceSelectionText(with: text, serviceID: serviceID, trigger: .button)
      }
    }

    do {
      settings = try settingsStore.load()
    } catch {
      settings = AppSettings.default
    }

    setupStatusItemIfNeeded()
    applySettings()
    startWorkspaceObservers()
  }

  func stop() {
    activeTranslationTask?.cancel()
    activeTranslationTask = nil
    stopWorkspaceObservers()
    hotKeyManager.unregisterAll()
    clearReplacementContext()
  }

  private func setupStatusItemIfNeeded() {
    guard statusItem == nil else {
      return
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.title = "即译"
      button.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    statusItem = item
    rebuildStatusMenu()
  }

  private func applySettings() {
    registerHotKeys()
    rebuildStatusMenu()
    preferencesWindowController?.refresh(settings)
  }

  private func registerHotKeys() {
    hotKeyManager.unregisterAll()

    let translateShortcut = settings.env.TRANSLATE_SHORTCUT
    let ocrShortcut = settings.env.OCR_TRANSLATE_SHORTCUT
    let openSettingsShortcut = settings.env.OPEN_SETTINGS_SHORTCUT

    translateHotKeyRegistered = hotKeyManager.register(shortcut: translateShortcut) { [weak self] in
      Task { @MainActor in
        self?.triggerTranslate()
      }
    } != nil

    ocrHotKeyRegistered = hotKeyManager.register(shortcut: ocrShortcut) { [weak self] in
      Task { @MainActor in
        self?.triggerOCRTranslate()
      }
    } != nil

    openSettingsHotKeyRegistered = hotKeyManager.register(shortcut: openSettingsShortcut) { [weak self] in
      Task { @MainActor in
        self?.openPreferences()
      }
    } != nil
  }

  private func rebuildStatusMenu() {
    guard let statusItem else {
      return
    }

    let activeService = settings.resolveActiveService()

    let menu = NSMenu()

    let translateItem = NSMenuItem(
      title: "翻译选中文本",
      action: #selector(handleTranslateAction),
      keyEquivalent: ""
    )
    translateItem.target = self
    menu.addItem(translateItem)

    let ocrItem = NSMenuItem(
      title: "截图 OCR 翻译",
      action: #selector(handleOCRTranslateAction),
      keyEquivalent: ""
    )
    ocrItem.target = self
    menu.addItem(ocrItem)

    let settingsItem = NSMenuItem(
      title: "偏好设置",
      action: #selector(handleOpenSettingsAction),
      keyEquivalent: ""
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let serviceTitle = "当前服务：\(activeService.name)"
    let serviceItem = NSMenuItem(title: serviceTitle, action: nil, keyEquivalent: "")
    serviceItem.isEnabled = false
    menu.addItem(serviceItem)

    let translateShortcutItem = NSMenuItem(
      title: "翻译快捷键：\(settings.env.TRANSLATE_SHORTCUT)",
      action: nil,
      keyEquivalent: ""
    )
    translateShortcutItem.isEnabled = translateHotKeyRegistered
    menu.addItem(translateShortcutItem)

    let ocrShortcutItem = NSMenuItem(
      title: "OCR 快捷键：\(settings.env.OCR_TRANSLATE_SHORTCUT)",
      action: nil,
      keyEquivalent: ""
    )
    ocrShortcutItem.isEnabled = ocrHotKeyRegistered
    menu.addItem(ocrShortcutItem)

    let openShortcutItem = NSMenuItem(
      title: "设置快捷键：\(settings.env.OPEN_SETTINGS_SHORTCUT)",
      action: nil,
      keyEquivalent: ""
    )
    openShortcutItem.isEnabled = openSettingsHotKeyRegistered
    menu.addItem(openShortcutItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(title: "退出", action: #selector(handleQuitAction), keyEquivalent: "")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem.menu = menu
  }

  @objc
  private func handleTranslateAction() {
    triggerTranslate()
  }

  @objc
  private func handleOCRTranslateAction() {
    triggerOCRTranslate()
  }

  @objc
  private func handleOpenSettingsAction() {
    openPreferences()
  }

  @objc
  private func handleQuitAction() {
    NSApplication.shared.terminate(nil)
  }

  private func triggerTranslate() {
    triggerTranslate(source: .selection)
  }

  private func triggerOCRTranslate() {
    triggerTranslate(source: .ocr)
  }

  private func triggerTranslate(source: TranslateSource) {
    let sourceProcessIdentifier = source == .selection ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil

    if isTranslating {
      let now = Date()
      let elapsed = now.timeIntervalSince(translationStartedAt ?? now)
      if elapsed < 180 {
        return
      }

      activeTranslationTask?.cancel()
      activeTranslationTask = nil
      isTranslating = false
      translationStartedAt = nil
    }

    isTranslating = true
    translationStartedAt = Date()

    let task = Task { [weak self] in
      guard let self else {
        return
      }
      await self.performTranslationFlow(source: source, sourceProcessIdentifier: sourceProcessIdentifier)
    }
    activeTranslationTask = task
  }

  private func cancelTranslationAfterBubbleDismiss() {
    guard isTranslating else {
      return
    }

    activeTranslationTask?.cancel()
    activeTranslationTask = nil
    isTranslating = false
    translationStartedAt = nil
  }

  private func performTranslationFlow(source: TranslateSource, sourceProcessIdentifier: pid_t?) async {
    defer {
      isTranslating = false
      activeTranslationTask = nil
      translationStartedAt = nil
    }

    let currentSettings = settings
    let popupMode = currentSettings.env.popupMode()
    let fontSize = currentSettings.env.fontSize()
    let thinkingDefaultExpanded = currentSettings.env.THINKING_DEFAULT_EXPANDED
    let activeService = currentSettings.resolveActiveService()
    let displayServices = currentSettings.resolveDisplayServices(for: popupMode)
    let automation = currentSettings.automation

    let payload: SelectionPayload
    do {
      payload = try await fetchSourcePayload(source: source)
    } catch {
      clearReplacementContext()
      if let ocrError = error as? OCRReaderError, ocrError == .cancelled {
        return
      }
      translatorWindowController.showFatalError(
        source: "",
        message: error.localizedDescription,
        fontSize: fontSize,
        popupMode: popupMode,
        anchor: nil
      )
      return
    }

    let preparedSource = preprocessSourceText(payload.text, automation: automation)
    configureReplacementContext(
      source: source,
      services: displayServices,
      sourceProcessIdentifier: sourceProcessIdentifier
    )

    translatorWindowController.showLoading(
      source: preparedSource,
      services: displayServices,
      activeServiceID: activeService.id,
      fontSize: fontSize,
      popupMode: popupMode,
      thinkingDefaultExpanded: thinkingDefaultExpanded,
      automation: automation,
      canReplaceSelection: canReplaceCurrentSelection,
      anchor: payload.anchor
    )

    if automation.autoPlaySourceText {
      speakSourceText(preparedSource)
    }

    let sourceText = preparedSource
    let glossary = currentSettings.glossary
    var hasAutoCopiedFirstResult = false
    var supplementTasks: [Task<ServiceSupplementOutcome, Never>] = []

    var streamingContinuation: AsyncStream<ServiceStreamingUpdate>.Continuation?
    let streamingUpdates = AsyncStream<ServiceStreamingUpdate> { continuation in
      streamingContinuation = continuation
    }

    let streamingConsumer = Task { @MainActor [weak self] in
      for await update in streamingUpdates {
        switch update.section {
        case .translation:
          self?.translatorWindowController.updateServiceStreaming(
            serviceID: update.serviceID,
            text: update.partialText,
            thinking: update.partialThinking
          )
        case .explanation:
          self?.translatorWindowController.updateServiceExplanationStreaming(
            serviceID: update.serviceID,
            text: update.partialText
          )
        case .englishLearning:
          self?.translatorWindowController.updateServiceLearningStreaming(
            serviceID: update.serviceID,
            text: update.partialText
          )
        }
      }
    }

    for service in displayServices {
      if service.enableExplanation {
        translatorWindowController.setServiceExplanationLoading(serviceID: service.id, isLoading: true)
        let client = translatorClient
        let continuation = streamingContinuation
        let serviceCopy = service
        supplementTasks.append(
          Task {
            do {
              let text = try await AppController.runWithTimeout(
                milliseconds: serviceCopy.timeoutMilliseconds
              ) {
                try await client.generateExplanationStreaming(
                  sourceText: sourceText,
                  translatedText: nil,
                  service: serviceCopy,
                  onUpdate: { progress in
                    continuation?.yield(
                      ServiceStreamingUpdate(
                        serviceID: serviceCopy.id,
                        section: .explanation,
                        partialText: progress,
                        partialThinking: ""
                      )
                    )
                  }
                )
              }
              return ServiceSupplementOutcome(
                serviceID: serviceCopy.id,
                kind: .explanation,
                text: text,
                errorMessage: nil
              )
            } catch {
              let translatorError = error as? TranslatorError
              let preview = translatorError?.responsePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              let message = translatorError?.localizedDescription ?? error.localizedDescription
              let merged = preview.isEmpty ? message : "\(message)\n接口返回：\(preview)"
              return ServiceSupplementOutcome(
                serviceID: serviceCopy.id,
                kind: .explanation,
                text: nil,
                errorMessage: merged
              )
            }
          }
        )
      }

      if service.enableEnglishLearning {
        translatorWindowController.setServiceLearningLoading(serviceID: service.id, isLoading: true)
        let client = translatorClient
        let continuation = streamingContinuation
        let serviceCopy = service
        supplementTasks.append(
          Task {
            do {
              let text = try await AppController.runWithTimeout(
                milliseconds: serviceCopy.timeoutMilliseconds
              ) {
                try await client.generateEnglishLearningStreaming(
                  sourceText: sourceText,
                  translatedText: nil,
                  service: serviceCopy,
                  onUpdate: { progress in
                    continuation?.yield(
                      ServiceStreamingUpdate(
                        serviceID: serviceCopy.id,
                        section: .englishLearning,
                        partialText: progress,
                        partialThinking: ""
                      )
                    )
                  }
                )
              }
              return ServiceSupplementOutcome(
                serviceID: serviceCopy.id,
                kind: .englishLearning,
                text: text,
                errorMessage: nil
              )
            } catch {
              let translatorError = error as? TranslatorError
              let preview = translatorError?.responsePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              let message = translatorError?.localizedDescription ?? error.localizedDescription
              let merged = preview.isEmpty ? message : "\(message)\n接口返回：\(preview)"
              return ServiceSupplementOutcome(
                serviceID: serviceCopy.id,
                kind: .englishLearning,
                text: nil,
                errorMessage: merged
              )
            }
          }
        )
      }
    }

    await withTaskGroup(of: ServiceTranslationOutcome.self) { group in
      for service in displayServices {
        let client = translatorClient
        let continuation = streamingContinuation
        group.addTask {
          do {
            let translated = try await AppController.runWithTimeout(
              milliseconds: service.timeoutMilliseconds
            ) {
              try await client.translateStreaming(
                text: sourceText,
                service: service,
                glossary: glossary,
                onUpdate: { progress in
                  continuation?.yield(
                    ServiceStreamingUpdate(
                      serviceID: service.id,
                      section: .translation,
                      partialText: progress.text,
                      partialThinking: progress.thinking
                    )
                  )
                }
              )
            }
            return ServiceTranslationOutcome(
              serviceID: service.id,
              translatedText: translated,
              errorMessage: nil,
              errorDetail: nil
            )
          } catch {
            let translatorError = error as? TranslatorError
            return ServiceTranslationOutcome(
              serviceID: service.id,
              translatedText: nil,
              errorMessage: translatorError?.localizedDescription ?? error.localizedDescription,
              errorDetail: translatorError?.responsePreview
            )
          }
        }
      }

      for await outcome in group {
        if Task.isCancelled {
          break
        }

        if let translatedText = outcome.translatedText {
          replaceableTranslationsByServiceID[outcome.serviceID] = translatedText
          translatorWindowController.updateServiceResult(
            serviceID: outcome.serviceID,
            result: translatedText
          )

          if automation.autoCopyFirstResult && !hasAutoCopiedFirstResult {
            autoCopyToClipboard(translatedText)
            hasAutoCopiedFirstResult = true
          }
        } else {
          replaceableTranslationsByServiceID.removeValue(forKey: outcome.serviceID)
          translatorWindowController.updateServiceError(
            serviceID: outcome.serviceID,
            message: outcome.errorMessage ?? "未知错误",
            detail: outcome.errorDetail
          )
        }
      }
    }

    for task in supplementTasks {
      if Task.isCancelled {
        task.cancel()
        continue
      }
      let outcome = await task.value
      switch outcome.kind {
      case .explanation:
        if let text = outcome.text {
          translatorWindowController.updateServiceExplanation(
            serviceID: outcome.serviceID,
            text: text,
            error: nil
          )
        } else {
          translatorWindowController.updateServiceExplanation(
            serviceID: outcome.serviceID,
            text: nil,
            error: outcome.errorMessage ?? "讲解生成失败"
          )
        }
      case .englishLearning:
        if let text = outcome.text {
          translatorWindowController.updateServiceLearning(
            serviceID: outcome.serviceID,
            text: text,
            error: nil
          )
        } else {
          translatorWindowController.updateServiceLearning(
            serviceID: outcome.serviceID,
            text: nil,
            error: outcome.errorMessage ?? "英语学习生成失败"
          )
        }
      }
    }

    streamingContinuation?.finish()
    await streamingConsumer.value

    translatorWindowController.finishCurrentTask()
  }

  private func fetchSourcePayload(source: TranslateSource) async throws -> SelectionPayload {
    switch source {
    case .selection:
      do {
        return try selectionReader.readSelection(promptIfNeeded: true)
      } catch {
        if let copied = copyFallbackReader.readSelectionText() {
          return SelectionPayload(text: copied, anchor: nil)
        }
        throw error
      }
    case .ocr:
      return try await ocrReader.readSelection()
    }
  }

  private func preprocessSourceText(_ source: String, automation: AutomationSettings) -> String {
    var value = source

    if automation.replaceLineBreaksWithSpace {
      value = value.replacingOccurrences(
        of: #"\s*[\r\n]+\s*"#,
        with: " ",
        options: .regularExpression
      )
    }

    if automation.stripCodeCommentMarkers {
      value = value.replacingOccurrences(of: "/*", with: "")
      value = value.replacingOccurrences(of: "*/", with: "")
      value = value.replacingOccurrences(
        of: #"(?m)^\s*(//|#)\s?"#,
        with: "",
        options: .regularExpression
      )
    }

    if automation.removeHyphenSpace {
      value = value.replacingOccurrences(
        of: #"([A-Za-z])-\s+([A-Za-z])"#,
        with: "$1$2",
        options: .regularExpression
      )
    }

    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func autoCopyToClipboard(_ text: String) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }

  private func configureReplacementContext(
    source: TranslateSource,
    services: [ServiceConfig],
    sourceProcessIdentifier: pid_t?
  ) {
    replaceShortcutServiceIDs = services.map(\.id)
    replaceShortcutServiceNames = services.reduce(into: [:]) { partial, service in
      partial[service.id] = service.name
    }
    replaceableTranslationsByServiceID.removeAll(keepingCapacity: false)
    canReplaceCurrentSelection = source == .selection
    replacementTargetProcessIdentifier = canReplaceCurrentSelection ? sourceProcessIdentifier : nil
    registerReplaceHotKeys()
  }

  private func clearReplacementContext() {
    replaceHotKeyManager.unregisterAll()
    replaceShortcutServiceIDs.removeAll(keepingCapacity: false)
    replaceShortcutServiceNames.removeAll(keepingCapacity: false)
    replaceableTranslationsByServiceID.removeAll(keepingCapacity: false)
    canReplaceCurrentSelection = false
    replacementTargetProcessIdentifier = nil
  }

  private func registerReplaceHotKeys() {
    replaceHotKeyManager.unregisterAll()
    guard canReplaceCurrentSelection else {
      return
    }

    for (index, _) in replaceShortcutServiceIDs.prefix(9).enumerated() {
      let shortcut = "Alt+\(index + 1)"
      _ = replaceHotKeyManager.register(shortcut: shortcut) { [weak self] in
        Task { @MainActor in
          self?.replaceWithShortcut(index: index)
        }
      }
    }
  }

  private enum ReplaceTrigger {
    case button
    case shortcut(Int)
  }

  private func replaceWithShortcut(index: Int) {
    guard canReplaceCurrentSelection else {
      return
    }
    guard index >= 0, index < replaceShortcutServiceIDs.count else {
      return
    }

    let serviceID = replaceShortcutServiceIDs[index]
    guard let translated = replaceableTranslationsByServiceID[serviceID] else {
      translatorWindowController.setGlobalMessage("Alt+\(index + 1) 对应服务译文尚未完成。")
      NSSound.beep()
      return
    }

    replaceSelectionText(with: translated, serviceID: serviceID, trigger: .shortcut(index + 1))
  }

  private func replaceSelectionText(with rawText: String, serviceID: String, trigger: ReplaceTrigger) {
    guard canReplaceCurrentSelection else {
      translatorWindowController.setGlobalMessage("当前任务不支持替换原文，仅选中文本翻译可用。")
      NSSound.beep()
      return
    }

    let translated = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !translated.isEmpty else {
      translatorWindowController.setGlobalMessage("译文为空，无法替换。")
      NSSound.beep()
      return
    }

    replaceableTranslationsByServiceID[serviceID] = translated
    let success = selectionReplacementWriter.replaceSelectionText(
      with: translated,
      targetProcessIdentifier: replacementTargetProcessIdentifier
    )

    if success {
      let serviceName = replaceShortcutServiceNames[serviceID] ?? serviceID
      switch trigger {
      case .button:
        translatorWindowController.setGlobalMessage("已替换为 \(serviceName) 的译文。")
      case let .shortcut(index):
        translatorWindowController.setGlobalMessage("已使用 Alt+\(index) 替换为 \(serviceName) 译文。")
      }
      return
    }

    translatorWindowController.setGlobalMessage("替换失败，请确认原应用仍有选区且已授权辅助功能。")
    NSSound.beep()
  }

  private func speakSourceText(_ text: String) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return
    }

    if speechSynthesizer.isSpeaking {
      speechSynthesizer.stopSpeaking()
    }
    _ = speechSynthesizer.startSpeaking(value)
  }

  private func openPreferences() {
    if let controller = preferencesWindowController {
      controller.refresh(settings)
      controller.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let controller = PreferencesWindowController(
      settings: settings,
      settingsPath: settingsStore.settingsURL.path,
      onSave: { [weak self] next in
        guard let self else {
          return
        }
        try self.saveSettings(next)
      },
      onOpenSettingsFile: { [weak self] in
        self?.openSettingsFile()
      }
    )

    preferencesWindowController = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func saveSettings(_ next: AppSettings) throws {
    try settingsStore.save(next)
    settings = try settingsStore.load()
    applySettings()
  }

  private func openSettingsFile() {
    NSWorkspace.shared.open(settingsStore.settingsURL)
  }

  private func startWorkspaceObservers() {
    guard workspaceObservers.isEmpty else {
      return
    }

    let center = NSWorkspace.shared.notificationCenter

    let wakeObserver = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.applySettings()
      }
    }

    let sessionObserver = center.addObserver(
      forName: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.applySettings()
      }
    }

    workspaceObservers = [wakeObserver, sessionObserver]
  }

  private func stopWorkspaceObservers() {
    guard !workspaceObservers.isEmpty else {
      return
    }

    let center = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers {
      center.removeObserver(observer)
    }
    workspaceObservers.removeAll()
  }

  private nonisolated static func runWithTimeout<T: Sendable>(
    milliseconds: Int,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let limited = max(1000, milliseconds)
    let timeoutNanos = UInt64(limited) * 1_000_000

    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanos)
        throw TranslatorError.requestTimedOut(milliseconds: limited)
      }

      guard let first = try await group.next() else {
        group.cancelAll()
        throw TranslatorError.requestFailed("翻译任务被中断")
      }

      group.cancelAll()
      return first
    }
  }
}
