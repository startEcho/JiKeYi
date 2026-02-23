import Foundation

enum PopupMode: String, Codable, CaseIterable, Sendable {
  case panel
  case bubble
}

struct EnvSettings: Codable, Equatable, Sendable {
  var ANTHROPIC_BASE_URL: String
  var ANTHROPIC_AUTH_TOKEN: String
  var API_TIMEOUT_MS: String
  var ANTHROPIC_MODEL: String
  var TARGET_LANGUAGE: String
  var TRANSLATE_SHORTCUT: String
  var OCR_TRANSLATE_SHORTCUT: String
  var OPEN_SETTINGS_SHORTCUT: String
  var POPUP_MODE: String
  var TRANSLATOR_FONT_SIZE: String
  var THINKING_DEFAULT_EXPANDED: Bool

  static let defaults = EnvSettings(
    ANTHROPIC_BASE_URL: "https://api.minimaxi.com/anthropic",
    ANTHROPIC_AUTH_TOKEN: "REPLACE_WITH_YOUR_API_KEY",
    API_TIMEOUT_MS: "120000",
    ANTHROPIC_MODEL: "MiniMax-M2.5",
    TARGET_LANGUAGE: "简体中文",
    TRANSLATE_SHORTCUT: "CommandOrControl+Shift+T",
    OCR_TRANSLATE_SHORTCUT: "CommandOrControl+Shift+S",
    OPEN_SETTINGS_SHORTCUT: "CommandOrControl+Shift+O",
    POPUP_MODE: "panel",
    TRANSLATOR_FONT_SIZE: "16",
    THINKING_DEFAULT_EXPANDED: false
  )

  init(
    ANTHROPIC_BASE_URL: String,
    ANTHROPIC_AUTH_TOKEN: String,
    API_TIMEOUT_MS: String,
    ANTHROPIC_MODEL: String,
    TARGET_LANGUAGE: String,
    TRANSLATE_SHORTCUT: String,
    OCR_TRANSLATE_SHORTCUT: String,
    OPEN_SETTINGS_SHORTCUT: String,
    POPUP_MODE: String,
    TRANSLATOR_FONT_SIZE: String,
    THINKING_DEFAULT_EXPANDED: Bool
  ) {
    self.ANTHROPIC_BASE_URL = ANTHROPIC_BASE_URL
    self.ANTHROPIC_AUTH_TOKEN = ANTHROPIC_AUTH_TOKEN
    self.API_TIMEOUT_MS = API_TIMEOUT_MS
    self.ANTHROPIC_MODEL = ANTHROPIC_MODEL
    self.TARGET_LANGUAGE = TARGET_LANGUAGE
    self.TRANSLATE_SHORTCUT = TRANSLATE_SHORTCUT
    self.OCR_TRANSLATE_SHORTCUT = OCR_TRANSLATE_SHORTCUT
    self.OPEN_SETTINGS_SHORTCUT = OPEN_SETTINGS_SHORTCUT
    self.POPUP_MODE = POPUP_MODE
    self.TRANSLATOR_FONT_SIZE = TRANSLATOR_FONT_SIZE
    self.THINKING_DEFAULT_EXPANDED = THINKING_DEFAULT_EXPANDED
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.ANTHROPIC_BASE_URL = try container.decodeIfPresent(String.self, forKey: .ANTHROPIC_BASE_URL) ?? Self.defaults.ANTHROPIC_BASE_URL
    self.ANTHROPIC_AUTH_TOKEN = try container.decodeIfPresent(String.self, forKey: .ANTHROPIC_AUTH_TOKEN) ?? Self.defaults.ANTHROPIC_AUTH_TOKEN
    self.API_TIMEOUT_MS = try container.decodeIfPresent(String.self, forKey: .API_TIMEOUT_MS) ?? Self.defaults.API_TIMEOUT_MS
    self.ANTHROPIC_MODEL = try container.decodeIfPresent(String.self, forKey: .ANTHROPIC_MODEL) ?? Self.defaults.ANTHROPIC_MODEL
    self.TARGET_LANGUAGE = try container.decodeIfPresent(String.self, forKey: .TARGET_LANGUAGE) ?? Self.defaults.TARGET_LANGUAGE
    self.TRANSLATE_SHORTCUT = try container.decodeIfPresent(String.self, forKey: .TRANSLATE_SHORTCUT) ?? Self.defaults.TRANSLATE_SHORTCUT
    self.OCR_TRANSLATE_SHORTCUT = try container.decodeIfPresent(String.self, forKey: .OCR_TRANSLATE_SHORTCUT) ?? Self.defaults.OCR_TRANSLATE_SHORTCUT
    self.OPEN_SETTINGS_SHORTCUT = try container.decodeIfPresent(String.self, forKey: .OPEN_SETTINGS_SHORTCUT) ?? Self.defaults.OPEN_SETTINGS_SHORTCUT
    self.POPUP_MODE = try container.decodeIfPresent(String.self, forKey: .POPUP_MODE) ?? Self.defaults.POPUP_MODE
    self.TRANSLATOR_FONT_SIZE = try container.decodeIfPresent(String.self, forKey: .TRANSLATOR_FONT_SIZE) ?? Self.defaults.TRANSLATOR_FONT_SIZE
    self.THINKING_DEFAULT_EXPANDED = try container.decodeIfPresent(Bool.self, forKey: .THINKING_DEFAULT_EXPANDED) ?? Self.defaults.THINKING_DEFAULT_EXPANDED
  }

  func normalized() -> EnvSettings {
    var next = self
    next.ANTHROPIC_BASE_URL = next.ANTHROPIC_BASE_URL.trimmed(or: Self.defaults.ANTHROPIC_BASE_URL)
    next.ANTHROPIC_AUTH_TOKEN = next.ANTHROPIC_AUTH_TOKEN.trimmed(or: Self.defaults.ANTHROPIC_AUTH_TOKEN)
    next.API_TIMEOUT_MS = normalizeTimeoutString(next.API_TIMEOUT_MS, fallback: Self.defaults.API_TIMEOUT_MS)
    next.ANTHROPIC_MODEL = next.ANTHROPIC_MODEL.trimmed(or: Self.defaults.ANTHROPIC_MODEL)
    next.TARGET_LANGUAGE = next.TARGET_LANGUAGE.trimmed(or: Self.defaults.TARGET_LANGUAGE)
    next.TRANSLATE_SHORTCUT = next.TRANSLATE_SHORTCUT.trimmed(or: Self.defaults.TRANSLATE_SHORTCUT)
    next.OCR_TRANSLATE_SHORTCUT = next.OCR_TRANSLATE_SHORTCUT.trimmed(or: Self.defaults.OCR_TRANSLATE_SHORTCUT)
    next.OPEN_SETTINGS_SHORTCUT = next.OPEN_SETTINGS_SHORTCUT.trimmed(or: Self.defaults.OPEN_SETTINGS_SHORTCUT)
    let popupMode = PopupMode(rawValue: next.POPUP_MODE.lowercased()) ?? .panel
    next.POPUP_MODE = popupMode.rawValue
    next.TRANSLATOR_FONT_SIZE = normalizeFontSizeString(next.TRANSLATOR_FONT_SIZE)
    return next
  }

  func popupMode() -> PopupMode {
    PopupMode(rawValue: POPUP_MODE.lowercased()) ?? .panel
  }

  func fontSize() -> Int {
    let parsed = Int(TRANSLATOR_FONT_SIZE.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 16
    return min(max(parsed, 12), 32)
  }
}

struct RoutingSettings: Codable, Equatable, Sendable {
  var autoRouteEnabled: Bool
  var fallbackEnabled: Bool

  static let defaults = RoutingSettings(autoRouteEnabled: true, fallbackEnabled: true)

  init(autoRouteEnabled: Bool, fallbackEnabled: Bool) {
    self.autoRouteEnabled = autoRouteEnabled
    self.fallbackEnabled = fallbackEnabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.autoRouteEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRouteEnabled) ?? Self.defaults.autoRouteEnabled
    self.fallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .fallbackEnabled) ?? Self.defaults.fallbackEnabled
  }
}

struct GlossaryItem: Codable, Equatable, Hashable, Sendable {
  var source: String
  var target: String

  init(source: String, target: String) {
    self.source = source
    self.target = target
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    self.target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
  }
}

struct AutomationSettings: Codable, Equatable, Sendable {
  var replaceLineBreaksWithSpace: Bool
  var stripCodeCommentMarkers: Bool
  var removeHyphenSpace: Bool
  var autoCopyOcrResult: Bool
  var autoCopyFirstResult: Bool
  var copyHighlightedWordOnClick: Bool
  var autoPlaySourceText: Bool

  static let defaults = AutomationSettings(
    replaceLineBreaksWithSpace: false,
    stripCodeCommentMarkers: false,
    removeHyphenSpace: false,
    autoCopyOcrResult: false,
    autoCopyFirstResult: false,
    copyHighlightedWordOnClick: false,
    autoPlaySourceText: false
  )

  init(
    replaceLineBreaksWithSpace: Bool,
    stripCodeCommentMarkers: Bool,
    removeHyphenSpace: Bool,
    autoCopyOcrResult: Bool,
    autoCopyFirstResult: Bool,
    copyHighlightedWordOnClick: Bool,
    autoPlaySourceText: Bool
  ) {
    self.replaceLineBreaksWithSpace = replaceLineBreaksWithSpace
    self.stripCodeCommentMarkers = stripCodeCommentMarkers
    self.removeHyphenSpace = removeHyphenSpace
    self.autoCopyOcrResult = autoCopyOcrResult
    self.autoCopyFirstResult = autoCopyFirstResult
    self.copyHighlightedWordOnClick = copyHighlightedWordOnClick
    self.autoPlaySourceText = autoPlaySourceText
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.replaceLineBreaksWithSpace = try container.decodeIfPresent(Bool.self, forKey: .replaceLineBreaksWithSpace) ?? Self.defaults.replaceLineBreaksWithSpace
    self.stripCodeCommentMarkers = try container.decodeIfPresent(Bool.self, forKey: .stripCodeCommentMarkers) ?? Self.defaults.stripCodeCommentMarkers
    self.removeHyphenSpace = try container.decodeIfPresent(Bool.self, forKey: .removeHyphenSpace) ?? Self.defaults.removeHyphenSpace
    self.autoCopyOcrResult = try container.decodeIfPresent(Bool.self, forKey: .autoCopyOcrResult) ?? Self.defaults.autoCopyOcrResult
    self.autoCopyFirstResult = try container.decodeIfPresent(Bool.self, forKey: .autoCopyFirstResult) ?? Self.defaults.autoCopyFirstResult
    self.copyHighlightedWordOnClick = try container.decodeIfPresent(Bool.self, forKey: .copyHighlightedWordOnClick) ?? Self.defaults.copyHighlightedWordOnClick
    self.autoPlaySourceText = try container.decodeIfPresent(Bool.self, forKey: .autoPlaySourceText) ?? Self.defaults.autoPlaySourceText
  }
}

struct ServiceConfig: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var enabled: Bool
  var baseUrl: String
  var apiKey: String
  var model: String
  var targetLanguage: String
  var timeoutMs: String
  var enableThinking: Bool
  var thinkingBudgetTokens: String
  var maxTokens: String
  var temperature: String
  var extraBodyJSON: String
  var enableExplanation: Bool
  var explanationPrompt: String
  var enableEnglishLearning: Bool
  var englishLearningPrompt: String

  init(
    id: String,
    name: String,
    enabled: Bool,
    baseUrl: String,
    apiKey: String,
    model: String,
    targetLanguage: String,
    timeoutMs: String,
    enableThinking: Bool = false,
    thinkingBudgetTokens: String = "1024",
    maxTokens: String = "",
    temperature: String = "0",
    extraBodyJSON: String = "",
    enableExplanation: Bool = false,
    explanationPrompt: String = "",
    enableEnglishLearning: Bool = false,
    englishLearningPrompt: String = ""
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.baseUrl = baseUrl
    self.apiKey = apiKey
    self.model = model
    self.targetLanguage = targetLanguage
    self.timeoutMs = timeoutMs
    self.enableThinking = enableThinking
    self.thinkingBudgetTokens = thinkingBudgetTokens
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.extraBodyJSON = extraBodyJSON
    self.enableExplanation = enableExplanation
    self.explanationPrompt = explanationPrompt
    self.enableEnglishLearning = enableEnglishLearning
    self.englishLearningPrompt = englishLearningPrompt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    self.baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
    self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    self.targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? ""
    self.timeoutMs = try container.decodeIfPresent(String.self, forKey: .timeoutMs) ?? ""
    self.enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? false
    self.thinkingBudgetTokens = try container.decodeIfPresent(String.self, forKey: .thinkingBudgetTokens) ?? "1024"
    self.maxTokens = try container.decodeIfPresent(String.self, forKey: .maxTokens) ?? ""
    self.temperature = try container.decodeIfPresent(String.self, forKey: .temperature) ?? "0"
    self.extraBodyJSON = try container.decodeIfPresent(String.self, forKey: .extraBodyJSON) ?? ""
    self.enableExplanation = try container.decodeIfPresent(Bool.self, forKey: .enableExplanation) ?? false
    self.explanationPrompt = try container.decodeIfPresent(String.self, forKey: .explanationPrompt) ?? ""
    self.enableEnglishLearning = try container.decodeIfPresent(Bool.self, forKey: .enableEnglishLearning) ?? false
    self.englishLearningPrompt = try container.decodeIfPresent(String.self, forKey: .englishLearningPrompt) ?? ""
  }

  static func defaultService(from env: EnvSettings, id: String = "svc_default", name: String = "默认服务") -> ServiceConfig {
    ServiceConfig(
      id: id,
      name: name,
      enabled: true,
      baseUrl: env.ANTHROPIC_BASE_URL,
      apiKey: env.ANTHROPIC_AUTH_TOKEN,
      model: env.ANTHROPIC_MODEL,
      targetLanguage: env.TARGET_LANGUAGE,
      timeoutMs: normalizeTimeoutString(env.API_TIMEOUT_MS, fallback: EnvSettings.defaults.API_TIMEOUT_MS),
      enableThinking: false,
      thinkingBudgetTokens: "1024",
      maxTokens: "",
      temperature: "0",
      extraBodyJSON: "",
      enableExplanation: false,
      explanationPrompt: "",
      enableEnglishLearning: false,
      englishLearningPrompt: ""
    )
  }

  func normalized(index: Int, env: EnvSettings) -> ServiceConfig {
    let fallback = ServiceConfig.defaultService(from: env, id: "svc_\(index + 1)", name: "服务 \(index + 1)")
    return ServiceConfig(
      id: id.trimmed(or: fallback.id),
      name: name.trimmed(or: fallback.name),
      enabled: enabled,
      baseUrl: baseUrl.trimmed(or: fallback.baseUrl),
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback.apiKey : apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      model: model.trimmed(or: fallback.model),
      targetLanguage: targetLanguage.trimmed(or: fallback.targetLanguage),
      timeoutMs: normalizeTimeoutString(timeoutMs, fallback: fallback.timeoutMs),
      enableThinking: enableThinking,
      thinkingBudgetTokens: normalizePositiveIntString(thinkingBudgetTokens, fallback: fallback.thinkingBudgetTokens),
      maxTokens: normalizeOptionalPositiveIntString(maxTokens),
      temperature: normalizeTemperatureString(temperature),
      extraBodyJSON: extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines),
      enableExplanation: enableExplanation,
      explanationPrompt: explanationPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
      enableEnglishLearning: enableEnglishLearning,
      englishLearningPrompt: englishLearningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  var timeoutMilliseconds: Int {
    let parsed = Int(timeoutMs.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 120000
    return max(1000, parsed)
  }

  var thinkingBudget: Int {
    let parsed = Int(thinkingBudgetTokens.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1024
    return max(1, parsed)
  }

  var resolvedMaxTokens: Int? {
    let value = maxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      return nil
    }
    guard let parsed = Int(value), parsed > 0 else {
      return nil
    }
    return parsed
  }

  var resolvedTemperature: Double {
    let parsed = Double(temperature.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    return min(max(parsed, 0), 2)
  }

  var normalizedExtraBodyJSON: String {
    extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  var activeServiceId: String
  var services: [ServiceConfig]
  var env: EnvSettings
  var routing: RoutingSettings
  var bubbleVisibleServiceIds: [String]
  var glossary: [GlossaryItem]
  var automation: AutomationSettings

  static let `default` = AppSettings(
    activeServiceId: "svc_default",
    services: [ServiceConfig.defaultService(from: EnvSettings.defaults)],
    env: EnvSettings.defaults,
    routing: RoutingSettings.defaults,
    bubbleVisibleServiceIds: [],
    glossary: [],
    automation: AutomationSettings.defaults
  )

  init(
    activeServiceId: String,
    services: [ServiceConfig],
    env: EnvSettings,
    routing: RoutingSettings,
    bubbleVisibleServiceIds: [String],
    glossary: [GlossaryItem],
    automation: AutomationSettings
  ) {
    self.activeServiceId = activeServiceId
    self.services = services
    self.env = env
    self.routing = routing
    self.bubbleVisibleServiceIds = bubbleVisibleServiceIds
    self.glossary = glossary
    self.automation = automation
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.activeServiceId = try container.decodeIfPresent(String.self, forKey: .activeServiceId) ?? "svc_default"
    self.services = try container.decodeIfPresent([ServiceConfig].self, forKey: .services) ?? []
    self.env = try container.decodeIfPresent(EnvSettings.self, forKey: .env) ?? EnvSettings.defaults
    self.routing = try container.decodeIfPresent(RoutingSettings.self, forKey: .routing) ?? RoutingSettings.defaults
    self.bubbleVisibleServiceIds = try container.decodeIfPresent([String].self, forKey: .bubbleVisibleServiceIds) ?? []
    self.glossary = try container.decodeIfPresent([GlossaryItem].self, forKey: .glossary) ?? []
    self.automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings.defaults
  }

  func normalized() -> AppSettings {
    var next = self
    next.env = next.env.normalized()

    var normalizedServices = next.services.enumerated().map { index, service in
      service.normalized(index: index, env: next.env)
    }
    if normalizedServices.isEmpty {
      normalizedServices = [ServiceConfig.defaultService(from: next.env)]
    }
    normalizedServices = dedupeServiceIDs(normalizedServices)
    next.services = normalizedServices

    let active = next.resolveActiveService()
    next.activeServiceId = active.id

    next.env.ANTHROPIC_BASE_URL = active.baseUrl
    next.env.ANTHROPIC_AUTH_TOKEN = active.apiKey
    next.env.ANTHROPIC_MODEL = active.model
    next.env.TARGET_LANGUAGE = active.targetLanguage
    next.env.API_TIMEOUT_MS = active.timeoutMs

    next.bubbleVisibleServiceIds = normalizeServiceIDList(next.bubbleVisibleServiceIds, services: next.services)
    next.glossary = normalizeGlossary(next.glossary)

    return next
  }

  func resolveActiveService() -> ServiceConfig {
    if let byID = services.first(where: { $0.id == activeServiceId }), byID.enabled {
      return byID
    }
    if let firstEnabled = services.first(where: { $0.enabled }) {
      return firstEnabled
    }
    return services.first ?? ServiceConfig.defaultService(from: env)
  }

  func resolveDisplayServices(for mode: PopupMode) -> [ServiceConfig] {
    let enabledServices = services.filter(\.enabled)
    let fallback = [resolveActiveService()]

    if enabledServices.isEmpty {
      return fallback
    }

    var candidates = enabledServices
    if mode == .bubble, !bubbleVisibleServiceIds.isEmpty {
      let visibleIDs = Set(bubbleVisibleServiceIds)
      let filtered = enabledServices.filter { visibleIDs.contains($0.id) }
      if !filtered.isEmpty {
        candidates = filtered
      }
    }

    let activeID = resolveActiveService().id
    return candidates.sorted { lhs, rhs in
      if lhs.id == activeID {
        return true
      }
      if rhs.id == activeID {
        return false
      }
      return lhs.name.localizedCompare(rhs.name) == .orderedAscending
    }
  }

  mutating func applyActiveService(_ serviceID: String) {
    let trimmed = serviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    if services.contains(where: { $0.id == trimmed }) {
      activeServiceId = trimmed
    }
    self = normalized()
  }
}

private func dedupeServiceIDs(_ services: [ServiceConfig]) -> [ServiceConfig] {
  var counters: [String: Int] = [:]
  var output: [ServiceConfig] = []

  for (index, service) in services.enumerated() {
    let fallbackID = "svc_\(index + 1)"
    let baseID = service.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackID : service.id
    let count = counters[baseID] ?? 0
    counters[baseID] = count + 1

    var next = service
    next.id = count == 0 ? baseID : "\(baseID)_\(count + 1)"
    output.append(next)
  }

  return output
}

private func normalizeServiceIDList(_ raw: [String], services: [ServiceConfig]) -> [String] {
  let validIDs = Set(services.map { $0.id })
  var dedupe = Set<String>()
  var result: [String] = []

  for item in raw {
    let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, validIDs.contains(trimmed), !dedupe.contains(trimmed) else {
      continue
    }
    dedupe.insert(trimmed)
    result.append(trimmed)
  }

  if !result.isEmpty {
    return result
  }

  let enabledIDs = services.filter(\.enabled).map(\.id)
  if !enabledIDs.isEmpty {
    return enabledIDs
  }

  return services.map(\.id)
}

private func normalizeGlossary(_ raw: [GlossaryItem]) -> [GlossaryItem] {
  var dedupe = Set<GlossaryItem>()
  var output: [GlossaryItem] = []

  for item in raw {
    let source = item.source.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty, !target.isEmpty else {
      continue
    }
    let next = GlossaryItem(source: source, target: target)
    guard !dedupe.contains(next) else {
      continue
    }
    dedupe.insert(next)
    output.append(next)
  }

  return output
}

private func normalizeTimeoutString(_ value: String, fallback: String) -> String {
  let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
  guard let parsed, parsed > 0 else {
    return fallback
  }
  return String(parsed)
}

private func normalizePositiveIntString(_ value: String, fallback: String) -> String {
  let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
  guard let parsed, parsed > 0 else {
    return fallback
  }
  return String(parsed)
}

private func normalizeOptionalPositiveIntString(_ value: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return ""
  }
  guard let parsed = Int(trimmed), parsed > 0 else {
    return ""
  }
  return String(parsed)
}

private func normalizeTemperatureString(_ value: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return "0"
  }
  let parsed = Double(trimmed) ?? 0
  let clamped = min(max(parsed, 0), 2)
  let formatter = NumberFormatter()
  formatter.maximumFractionDigits = 2
  formatter.minimumFractionDigits = 0
  formatter.minimumIntegerDigits = 1
  formatter.decimalSeparator = "."
  return formatter.string(from: NSNumber(value: clamped)) ?? "0"
}

private func normalizeFontSizeString(_ value: String) -> String {
  let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 16
  return String(min(max(parsed, 12), 32))
}

private extension String {
  func trimmed(or fallback: String) -> String {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}
