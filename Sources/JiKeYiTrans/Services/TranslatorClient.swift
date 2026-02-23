import Foundation

enum TranslatorError: LocalizedError {
  case invalidConfiguration
  case invalidURL(String)
  case invalidExtraBodyJSON(String)
  case requestFailed(String)
  case httpError(statusCode: Int, responseBody: String?)
  case requestTimedOut(milliseconds: Int)
  case stoppedBeforeAnswer(reason: String, responseBody: String?)
  case emptyResponse(responseBody: String?)
  case invalidResponseFormat(responseBody: String?)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "翻译配置不完整，请检查 Base URL / API Key / Model。"
    case let .invalidURL(url):
      return "无效的服务地址：\(url)"
    case let .invalidExtraBodyJSON(message):
      return "附加请求参数 JSON 无效：\(message)"
    case let .requestFailed(message):
      return message
    case let .httpError(statusCode, _):
      return "翻译请求失败（HTTP \(statusCode)）。"
    case let .requestTimedOut(milliseconds):
      let seconds = max(1, milliseconds / 1000)
      return "请求超时（\(seconds)s），可在偏好设置把“超时毫秒”调大后重试。"
    case let .stoppedBeforeAnswer(reason, _):
      return "模型在返回译文前已停止（\(reason)）。可尝试关闭思考模式或稍后重试。"
    case .emptyResponse:
      return "接口返回为空，未获取到译文。"
    case .invalidResponseFormat:
      return "接口返回格式异常，未能解析译文。"
    }
  }

  var responsePreview: String? {
    switch self {
    case let .httpError(_, responseBody):
      return responseBody
    case let .stoppedBeforeAnswer(_, responseBody):
      return responseBody
    case let .emptyResponse(responseBody):
      return responseBody
    case let .invalidResponseFormat(responseBody):
      return responseBody
    default:
      return nil
    }
  }
}

struct TranslationStreamUpdate: Sendable {
  let text: String
  let thinking: String
}

actor TranslatorClient {
  private enum SupplementKind: Sendable {
    case explanation
    case englishLearning
  }

  private let session: URLSession
  private var cache: [String: String] = [:]
  private var cacheOrder: [String] = []
  private let cacheLimit = 200

  init(session: URLSession = .shared) {
    self.session = session
  }

  func translate(text: String, settings: AppSettings) async throws -> String {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      return ""
    }

    let service = settings.resolveActiveService()
    return try await translate(text: input, service: service, glossary: settings.glossary)
  }

  func translate(text: String, service: ServiceConfig, glossary: [GlossaryItem]) async throws -> String {
    try await translateStreaming(text: text, service: service, glossary: glossary, onUpdate: nil)
  }

  func translateStreaming(
    text: String,
    service: ServiceConfig,
    glossary: [GlossaryItem],
    onUpdate: (@Sendable (TranslationStreamUpdate) -> Void)?
  ) async throws -> String {
    try await translateStreamingOnce(
      text: text,
      service: service,
      glossary: glossary,
      onUpdate: onUpdate
    )
  }

  func generateExplanation(
    sourceText: String,
    translatedText: String? = nil,
    service: ServiceConfig
  ) async throws -> String {
    try await generateExplanationStreaming(
      sourceText: sourceText,
      translatedText: translatedText,
      service: service,
      onUpdate: nil
    )
  }

  func generateExplanationStreaming(
    sourceText: String,
    translatedText: String? = nil,
    service: ServiceConfig,
    onUpdate: (@Sendable (String) -> Void)?
  ) async throws -> String {
    try await generateSupplement(
      sourceText: sourceText,
      translatedText: translatedText,
      service: service,
      kind: .explanation,
      onUpdate: onUpdate
    )
  }

  func generateEnglishLearning(
    sourceText: String,
    translatedText: String? = nil,
    service: ServiceConfig
  ) async throws -> String {
    try await generateEnglishLearningStreaming(
      sourceText: sourceText,
      translatedText: translatedText,
      service: service,
      onUpdate: nil
    )
  }

  func generateEnglishLearningStreaming(
    sourceText: String,
    translatedText: String? = nil,
    service: ServiceConfig,
    onUpdate: (@Sendable (String) -> Void)?
  ) async throws -> String {
    try await generateSupplement(
      sourceText: sourceText,
      translatedText: translatedText,
      service: service,
      kind: .englishLearning,
      onUpdate: onUpdate
    )
  }

  private func translateStreamingOnce(
    text: String,
    service: ServiceConfig,
    glossary: [GlossaryItem],
    onUpdate: (@Sendable (TranslationStreamUpdate) -> Void)?
  ) async throws -> String {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      return ""
    }

    guard !service.baseUrl.isEmpty, !service.apiKey.isEmpty, !service.model.isEmpty else {
      throw TranslatorError.invalidConfiguration
    }

    let cacheKey = buildCacheKey(service: service, glossary: glossary, text: input)
    if let cached = readCache(cacheKey) {
      onUpdate?(TranslationStreamUpdate(text: cached, thinking: ""))
      return cached
    }

    let endpointURL = try buildEndpoint(baseURL: service.baseUrl)

    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(service.apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("Bearer \(service.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = TimeInterval(service.timeoutMilliseconds) / 1000.0

    let requestPayload = try buildRequestPayload(
      input: input,
      service: service,
      glossary: glossary
    )
    request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch let urlError as URLError where urlError.code == .timedOut {
      throw TranslatorError.requestTimedOut(milliseconds: service.timeoutMilliseconds)
    } catch {
      throw TranslatorError.requestFailed(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranslatorError.requestFailed("无效的网络响应")
    }

    if !(200 ..< 300).contains(httpResponse.statusCode) {
      throw TranslatorError.httpError(
        statusCode: httpResponse.statusCode,
        responseBody: try await previewResponseBody(from: bytes)
      )
    }

    var collector = StreamResponseCollector()
    var eventLines: [String] = []
    let collectThinking = service.enableThinking
    var translated = ""
    var thinking = ""
    var stopReason = ""
    var sawSSEDataLine = false

    func emitIfNeeded(text nextText: String, thinking nextThinking: String) {
      let normalizedText = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedThinking = collectThinking
        ? nextThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        : ""
      guard normalizedText != translated || normalizedThinking != thinking else {
        return
      }
      translated = normalizedText
      thinking = normalizedThinking
      onUpdate?(TranslationStreamUpdate(text: normalizedText, thinking: normalizedThinking))
    }

    func flushEventLines() {
      guard !eventLines.isEmpty else {
        return
      }

      let payload = eventLines.joined(separator: "\n")
      eventLines.removeAll(keepingCapacity: true)

      let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedPayload.isEmpty, trimmedPayload != "[DONE]" else {
        return
      }

      guard let json = parseJSONObject(from: trimmedPayload) else {
        return
      }

      if let reason = extractStopReason(from: json), !reason.isEmpty {
        stopReason = reason
      }

      var nextText = translated
      var nextThinking = thinking
      var changed = false

      if let delta = extractDeltaText(from: json), !delta.isEmpty {
        nextText += delta
        changed = true
      } else if let full = extractFinalText(from: json), !full.isEmpty, full != nextText {
        nextText = full
        changed = true
      }

      if collectThinking {
        if let deltaThinking = extractDeltaThinking(from: json), !deltaThinking.isEmpty {
          nextThinking += deltaThinking
          changed = true
        } else if let fullThinking = extractFinalThinking(from: json),
                  !fullThinking.isEmpty,
                  fullThinking != nextThinking
        {
          nextThinking = fullThinking
          changed = true
        }
      }

      if changed {
        emitIfNeeded(text: nextText, thinking: nextThinking)
      }
    }

    for try await rawLine in bytes.lines {
      collector.append(rawLine + "\n")
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

      if line.hasPrefix("event:") {
        flushEventLines()
        continue
      }

      if line.isEmpty {
        flushEventLines()
        continue
      }

      if line.hasPrefix(":") {
        continue
      }

      if line.hasPrefix("data:") {
        sawSSEDataLine = true
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        eventLines.append(payload)
        continue
      }
    }

    flushEventLines()

    if translated.isEmpty {
      let raw = collector.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !raw.isEmpty, let fallback = extractFinalText(fromJSONPayload: raw) {
        emitIfNeeded(text: fallback, thinking: thinking)
      } else if collectThinking,
                !raw.isEmpty,
                let fallbackThinking = extractFinalThinking(fromJSONPayload: raw)
      {
        emitIfNeeded(text: translated, thinking: fallbackThinking)
      } else if !raw.isEmpty, !sawSSEDataLine {
        throw TranslatorError.invalidResponseFormat(responseBody: collector.previewText())
      }
    }

    guard !translated.isEmpty else {
      if stopReason == "max_tokens" {
        throw TranslatorError.stoppedBeforeAnswer(
          reason: stopReason,
          responseBody: collector.previewText()
        )
      }
      throw TranslatorError.emptyResponse(responseBody: collector.previewText())
    }

    writeCache(cacheKey, value: translated)
    return translated
  }

  private func generateSupplement(
    sourceText: String,
    translatedText: String?,
    service: ServiceConfig,
    kind: SupplementKind,
    onUpdate: (@Sendable (String) -> Void)?
  ) async throws -> String {
    let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let translated = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !source.isEmpty else {
      return ""
    }

    guard !service.baseUrl.isEmpty, !service.apiKey.isEmpty, !service.model.isEmpty else {
      throw TranslatorError.invalidConfiguration
    }

    let endpointURL = try buildEndpoint(baseURL: service.baseUrl)
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(service.apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("Bearer \(service.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = TimeInterval(service.timeoutMilliseconds) / 1000.0
    request.httpBody = try JSONSerialization.data(
      withJSONObject: try buildSupplementRequestPayload(
        sourceText: source,
        translatedText: translated,
        service: service,
        kind: kind
      )
    )

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch let urlError as URLError where urlError.code == .timedOut {
      throw TranslatorError.requestTimedOut(milliseconds: service.timeoutMilliseconds)
    } catch {
      throw TranslatorError.requestFailed(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranslatorError.requestFailed("无效的网络响应")
    }

    if !(200 ..< 300).contains(httpResponse.statusCode) {
      throw TranslatorError.httpError(
        statusCode: httpResponse.statusCode,
        responseBody: try await previewResponseBody(from: bytes)
      )
    }

    var collector = StreamResponseCollector()
    var eventLines: [String] = []
    var output = ""
    var stopReason = ""
    var sawSSEDataLine = false

    func emitIfNeeded(_ next: String) {
      let normalized = normalizeSupplementStreamingText(next)
      guard normalized != output else {
        return
      }
      output = normalized
      onUpdate?(normalized)
    }

    func flushEventLines() {
      guard !eventLines.isEmpty else {
        return
      }

      let payload = eventLines.joined(separator: "\n")
      eventLines.removeAll(keepingCapacity: true)

      let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedPayload.isEmpty, trimmedPayload != "[DONE]" else {
        return
      }

      guard let json = parseJSONObject(from: trimmedPayload) else {
        return
      }

      if let reason = extractStopReason(from: json), !reason.isEmpty {
        stopReason = reason
      }

      var nextText = output
      var changed = false

      if let delta = extractDeltaText(from: json), !delta.isEmpty {
        nextText += delta
        changed = true
      } else if let full = extractFinalText(from: json), !full.isEmpty, full != nextText {
        nextText = full
        changed = true
      }

      if changed {
        emitIfNeeded(nextText)
      }
    }

    for try await rawLine in bytes.lines {
      collector.append(rawLine + "\n")
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

      if line.hasPrefix("event:") {
        flushEventLines()
        continue
      }

      if line.isEmpty {
        flushEventLines()
        continue
      }

      if line.hasPrefix(":") {
        continue
      }

      if line.hasPrefix("data:") {
        sawSSEDataLine = true
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        eventLines.append(payload)
      }
    }

    flushEventLines()

    if output.isEmpty {
      let raw = collector.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !raw.isEmpty, let fallback = extractFinalText(fromJSONPayload: raw) {
        emitIfNeeded(fallback)
      } else if !raw.isEmpty, !sawSSEDataLine {
        if let data = raw.data(using: .utf8),
           let fallback = extractText(fromResponseData: data),
           !fallback.isEmpty
        {
          emitIfNeeded(fallback)
        } else {
          throw TranslatorError.invalidResponseFormat(responseBody: collector.previewText())
        }
      }
    }

    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      if stopReason == "max_tokens" {
        throw TranslatorError.stoppedBeforeAnswer(reason: stopReason, responseBody: collector.previewText())
      }
      throw TranslatorError.emptyResponse(responseBody: collector.previewText())
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizeSupplementStreamingText(_ text: String) -> String {
    let normalizedLineEnding = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    if !normalizedLineEnding.contains("\n"), normalizedLineEnding.contains("\\n") {
      return normalizedLineEnding
        .replacingOccurrences(of: "\\r\\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\r", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
    }

    return normalizedLineEnding
  }

  private func readCache(_ key: String) -> String? {
    guard let value = cache[key] else {
      return nil
    }

    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    return value
  }

  private func writeCache(_ key: String, value: String) {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return
    }

    cache[key] = text
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)

    while cacheOrder.count > cacheLimit {
      let expired = cacheOrder.removeFirst()
      cache.removeValue(forKey: expired)
    }
  }

  private func buildEndpoint(baseURL: String) throws -> URL {
    let cleaned = baseURL.replacingOccurrences(of: #"/+\z"#, with: "", options: .regularExpression)
    guard let rootURL = URL(string: cleaned) else {
      throw TranslatorError.invalidURL(baseURL)
    }

    return rootURL.appending(path: "v1/messages")
  }

  private func buildSystemPrompt(
    sourceText: String,
    targetLanguage: String,
    glossary: [GlossaryItem],
    allowThinking: Bool
  ) -> String {
    let fallbackLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "简体中文"
      : targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedLanguage = resolveTargetLanguage(for: sourceText, fallbackLanguage: fallbackLanguage)

    let thinkingHint = allowThinking ? "可输出思考过程，但最后必须输出完整译文。" : "不要输出思考过程。"
    let base = """
    自动识别源文本语言并双向翻译：
    - 源文本以中文为主时，翻译为英文；
    - 源文本以英文为主时，翻译为简体中文；
    - 无法明确判定或非中英文文本时，翻译为\(fallbackLanguage)。
    当前任务目标语言：\(resolvedLanguage)。
    只输出译文，不要解释；保留原有换行、列表、代码标记、URL、数字与大小写。\(thinkingHint)
    """
    guard !glossary.isEmpty else {
      return base
    }

    let lines = glossary
      .map { "\($0.source) => \($0.target)" }
      .joined(separator: "\n")

    return "\(base)\n\n术语表（命中时优先使用右侧译法）：\n\(lines)"
  }

  private func resolveTargetLanguage(for sourceText: String, fallbackLanguage: String) -> String {
    let zhCount = sourceText.unicodeScalars.reduce(into: 0) { count, scalar in
      let value = scalar.value
      if (0x4E00 ... 0x9FFF).contains(value) || (0x3400 ... 0x4DBF).contains(value) {
        count += 1
      }
    }

    let enCount = sourceText.unicodeScalars.reduce(into: 0) { count, scalar in
      let value = scalar.value
      if (65 ... 90).contains(value) || (97 ... 122).contains(value) {
        count += 1
      }
    }

    if zhCount == 0, enCount == 0 {
      return fallbackLanguage
    }

    if zhCount == 0 {
      return "简体中文"
    }

    if enCount == 0 {
      return "英文"
    }

    if zhCount >= enCount * 2 {
      return "英文"
    }

    if enCount >= zhCount * 2 {
      return "简体中文"
    }

    return fallbackLanguage
  }

  private func defaultExplanationPrompt() -> String {
    """
    你是资深双语内容讲解助手。请使用简体中文，对“原文+译文”做深入讲解，目标是让用户彻底理解内容与专业背景。
    只输出标准 Markdown（GFM）：
    - 使用 `##` 二级标题组织内容；
    - 使用 `-` 无序列表；
    - 段落与段落之间必须空一行；
    - 需要表格时，必须使用标准 Markdown 表格语法（`|` + 分隔行），不要使用全角竖线 `｜`；
    - 不要输出 HTML，不要把多段内容压成一行。

    输出结构必须按下面标题顺序：
    ## 核心含义
    ## 深入讲解
    ## 术语与背景
    ## 翻译取舍与替代表达

    内容要求：
    1. “核心含义”先用 2-4 句总结核心观点。
    2. “深入讲解”解释关键概念、上下文和专业背景，不要泛泛而谈。
    3. “术语与背景”对术语给出通俗解释和语境下的精确定义。
    4. “翻译取舍与替代表达”指出翻译策略、潜在歧义，并给出更自然译法。
    5. 信息密度高，但格式清晰可读。

    原文：
    {{source}}

    译文：
    {{translation}}
    """
  }

  private func defaultEnglishLearningPrompt() -> String {
    """
    你是英语教学专家。请基于“原文+译文”给出可学习的深度讲解，输出简体中文，示例保留英文。
    只输出标准 Markdown（GFM）：
    - 使用 `##` 二级标题；
    - 使用 `-` 无序列表；
    - 段落之间空一行；
    - 表格必须使用标准 Markdown 表格语法（`|` + 分隔行），不要使用全角竖线 `｜`；
    - 不要输出 HTML，不要把多段内容压成一行。

    输出结构必须按下面标题顺序：
    ## 句法与结构
    ## 时态语态与语法点
    ## 词汇与短语精讲
    ## 可替换表达与地道改写
    ## 学习要点清单

    其中“词汇与短语精讲”必须包含一个标准 Markdown 表格，建议列为：
    | 词项 | 词性/类型 | 中文义 | 解析 | 近义词/搭配 | 例句 |
    | --- | --- | --- | --- | --- | --- |

    内容要求：
    1. 拆解句子结构（主谓宾、从句、并列、修饰关系）。
    2. 讲清时态/语态/语气及其表达效果。
    3. 对可能陌生词给出词性、中文义、近义词、常见搭配与例句。
    4. 指出易错点和中国学习者常见误区。
    5. 提供 2-3 个同义改写，以及 1 个更地道表达。

    原文：
    {{source}}

    译文：
    {{translation}}
    """
  }

  private func resolveSupplementPrompt(
    kind: SupplementKind,
    service: ServiceConfig,
    sourceText: String,
    translatedText: String?
  ) -> String {
    let custom = {
      switch kind {
      case .explanation:
        return service.explanationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      case .englishLearning:
        return service.englishLearningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }()

    let template: String
    if custom.isEmpty {
      switch kind {
      case .explanation:
        template = defaultExplanationPrompt()
      case .englishLearning:
        template = defaultEnglishLearningPrompt()
      }
    } else {
      template = custom
    }

    let normalizedTranslation = translatedText?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let translationPlaceholder = normalizedTranslation.isEmpty
      ? "（译文未提供，请先基于原文进行讲解，并在必要处给出你建议的译法。）"
      : normalizedTranslation

    let resolved = template
      .replacingOccurrences(of: "{{source}}", with: sourceText)
      .replacingOccurrences(of: "{{translation}}", with: translationPlaceholder)
      .replacingOccurrences(of: "{{target_language}}", with: service.targetLanguage)

    return "\(resolved)\n\n\(supplementMarkdownFormatRequirements(kind: kind))"
  }

  private func supplementMarkdownFormatRequirements(kind: SupplementKind) -> String {
    switch kind {
    case .explanation:
      return """
      最终输出格式约束（必须遵守）：
      1. 仅输出标准 Markdown（GFM），不要输出 HTML。
      2. 使用 `##` 标题、`-` 列表，段落之间空一行。
      3. 若使用表格，必须是标准 Markdown 表格（`|` + 分隔行），不要使用全角竖线 `｜`。
      4. 不要把多段信息挤在同一行。
      """
    case .englishLearning:
      return """
      最终输出格式约束（必须遵守）：
      1. 仅输出标准 Markdown（GFM），不要输出 HTML。
      2. 使用 `##` 标题、`-` 列表，段落之间空一行。
      3. “词汇与短语精讲”必须包含标准 Markdown 表格（`|` + 分隔行）；禁止全角竖线 `｜`。
      4. 不要把多段信息挤在同一行。
      """
    }
  }

  private func buildCacheKey(service: ServiceConfig, glossary: [GlossaryItem], text: String) -> String {
    let glossarySignature = glossary.map { "\($0.source)=>\($0.target)" }.joined(separator: "|")
    return [
      service.baseUrl,
      service.model,
      service.targetLanguage,
      service.enableThinking ? "show_thinking:on" : "show_thinking:off",
      service.temperature,
      service.normalizedExtraBodyJSON,
      glossarySignature,
      text
    ].joined(separator: "\u{0001}")
  }

  private func buildRequestPayload(
    input: String,
    service: ServiceConfig,
    glossary: [GlossaryItem]
  ) throws -> [String: Any] {
    var payload: [String: Any] = [:]

    if let extra = try parseExtraBodyJSONObject(service.normalizedExtraBodyJSON) {
      payload.merge(extra) { _, new in new }
    }

    payload["model"] = service.model
    payload["stream"] = true
    payload["system"] = buildSystemPrompt(
      sourceText: input,
      targetLanguage: service.targetLanguage,
      glossary: glossary,
      allowThinking: service.enableThinking
    )
    payload["messages"] = [["role": "user", "content": input]]
    payload["temperature"] = service.resolvedTemperature

    return payload
  }

  private func buildSupplementRequestPayload(
    sourceText: String,
    translatedText: String?,
    service: ServiceConfig,
    kind: SupplementKind
  ) throws -> [String: Any] {
    var payload: [String: Any] = [:]
    if let extra = try parseExtraBodyJSONObject(service.normalizedExtraBodyJSON) {
      payload.merge(extra) { _, new in new }
    }

    payload["model"] = service.model
    payload["stream"] = true
    payload["temperature"] = service.resolvedTemperature
    payload["system"] = "你是严谨、结构化、可读性强的语言助手。"
    payload["messages"] = [[
      "role": "user",
      "content": resolveSupplementPrompt(
        kind: kind,
        service: service,
        sourceText: sourceText,
        translatedText: translatedText
      )
    ]]
    return payload
  }

  private func parseExtraBodyJSONObject(_ raw: String) throws -> [String: Any]? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    guard let data = trimmed.data(using: .utf8) else {
      throw TranslatorError.invalidExtraBodyJSON("无法按 UTF-8 解析")
    }

    do {
      let object = try JSONSerialization.jsonObject(with: data)
      guard let dictionary = object as? [String: Any] else {
        throw TranslatorError.invalidExtraBodyJSON("必须是 JSON 对象")
      }
      return dictionary
    } catch let error as TranslatorError {
      throw error
    } catch {
      throw TranslatorError.invalidExtraBodyJSON(error.localizedDescription)
    }
  }

  private func extractText(fromResponseData data: Data) -> String? {
    if let object = try? JSONSerialization.jsonObject(with: data),
       let dict = object as? [String: Any]
    {
      if let full = extractFinalText(from: dict), !full.isEmpty {
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let delta = extractDeltaText(from: dict), !delta.isEmpty {
        return delta.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    if let raw = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    {
      if let fallback = extractFinalText(fromJSONPayload: raw), !fallback.isEmpty {
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      return raw.count > 8_000 ? String(raw.prefix(8_000)) : raw
    }

    return nil
  }

  private func previewResponseBody(from data: Data) -> String? {
    guard let raw = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    return raw.count > 8_000 ? String(raw.prefix(8_000)) : raw
  }

  private func previewResponseBody(from bytes: URLSession.AsyncBytes) async throws -> String? {
    var collector = StreamResponseCollector()
    for try await line in bytes.lines {
      collector.append(line + "\n")
    }
    return collector.previewText()
  }

  private func extractFinalText(fromJSONPayload payload: String) -> String? {
    guard let json = parseJSONObject(from: payload) else {
      return nil
    }
    return extractFinalText(from: json)
  }

  private func extractFinalThinking(fromJSONPayload payload: String) -> String? {
    guard let json = parseJSONObject(from: payload) else {
      return nil
    }
    return extractFinalThinking(from: json)
  }

  private func parseJSONObject(from payload: String) -> [String: Any]? {
    guard let data = payload.data(using: .utf8) else {
      return nil
    }
    guard let value = try? JSONSerialization.jsonObject(with: data),
          let dict = value as? [String: Any]
    else {
      return nil
    }
    return dict
  }

  private func extractDeltaText(from json: [String: Any]) -> String? {
    if let delta = json["delta"] as? [String: Any],
       let text = delta["text"] as? String,
       !text.isEmpty
    {
      return text
    }

    if let block = json["content_block"] as? [String: Any],
       let text = block["text"] as? String,
       !text.isEmpty
    {
      return text
    }

    if let choices = json["choices"] as? [[String: Any]] {
      var fragments: [String] = []
      for choice in choices {
        if let delta = choice["delta"] as? [String: Any] {
          if let content = delta["content"] as? String, !content.isEmpty {
            fragments.append(content)
          } else if let contentList = delta["content"] as? [[String: Any]] {
            let parts = contentList.compactMap { $0["text"] as? String }
            if !parts.isEmpty {
              fragments.append(parts.joined())
            }
          }
        } else if let text = choice["text"] as? String, !text.isEmpty {
          fragments.append(text)
        }
      }
      let joined = fragments.joined()
      if !joined.isEmpty {
        return joined
      }
    }

    return nil
  }

  private func extractDeltaThinking(from json: [String: Any]) -> String? {
    if let delta = json["delta"] as? [String: Any],
       let thinking = delta["thinking"] as? String,
       !thinking.isEmpty
    {
      return thinking
    }

    if let contentBlock = json["content_block"] as? [String: Any],
       let thinking = contentBlock["thinking"] as? String,
       !thinking.isEmpty
    {
      return thinking
    }

    if let choices = json["choices"] as? [[String: Any]] {
      var fragments: [String] = []
      for choice in choices {
        guard let delta = choice["delta"] as? [String: Any] else {
          continue
        }

        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
          fragments.append(reasoning)
        } else if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
          fragments.append(reasoning)
        } else if let contentList = delta["content"] as? [[String: Any]] {
          for item in contentList {
            let type = (item["type"] as? String)?.lowercased() ?? ""
            guard type == "thinking" || type == "reasoning" else {
              continue
            }
            if let text = item["text"] as? String, !text.isEmpty {
              fragments.append(text)
            } else if let thinking = item["thinking"] as? String, !thinking.isEmpty {
              fragments.append(thinking)
            }
          }
        }
      }

      let joined = fragments.joined()
      if !joined.isEmpty {
        return joined
      }
    }

    return nil
  }

  private func extractStopReason(from json: [String: Any]) -> String? {
    if let delta = json["delta"] as? [String: Any],
       let reason = delta["stop_reason"] as? String,
       !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return reason
    }

    if let message = json["message"] as? [String: Any],
       let reason = message["stop_reason"] as? String,
       !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return reason
    }

    if let reason = json["stop_reason"] as? String,
       !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return reason
    }

    if let choices = json["choices"] as? [[String: Any]] {
      for choice in choices {
        if let reason = choice["finish_reason"] as? String,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return reason
        }
      }
    }

    return nil
  }

  private func extractFinalText(from json: [String: Any]) -> String? {
    if let content = json["content"] as? [[String: Any]] {
      let texts = content.compactMap { block -> String? in
        if let text = block["text"] as? String, !text.isEmpty {
          return text
        }
        return nil
      }
      let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty {
        return joined
      }
    }

    if let choices = json["choices"] as? [[String: Any]] {
      let texts = choices.compactMap { choice -> String? in
        if let message = choice["message"] as? [String: Any] {
          if let content = message["content"] as? String, !content.isEmpty {
            return content
          }
          if let contentList = message["content"] as? [[String: Any]] {
            let parts = contentList.compactMap { $0["text"] as? String }
            let joined = parts.joined()
            return joined.isEmpty ? nil : joined
          }
        }
        if let text = choice["text"] as? String, !text.isEmpty {
          return text
        }
        return nil
      }

      let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty {
        return joined
      }
    }

    if let outputText = json["output_text"] as? String {
      let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    return nil
  }

  private func extractFinalThinking(from json: [String: Any]) -> String? {
    if let content = json["content"] as? [[String: Any]] {
      let thoughts = content.compactMap { block -> String? in
        let type = (block["type"] as? String)?.lowercased() ?? ""
        guard type == "thinking" || type == "reasoning" else {
          return nil
        }
        if let thinking = block["thinking"] as? String, !thinking.isEmpty {
          return thinking
        }
        if let text = block["text"] as? String, !text.isEmpty {
          return text
        }
        return nil
      }
      let joined = thoughts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty {
        return joined
      }
    }

    if let choices = json["choices"] as? [[String: Any]] {
      let thoughts = choices.compactMap { choice -> String? in
        if let message = choice["message"] as? [String: Any] {
          if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            return reasoning
          }
          if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
            return reasoning
          }
          if let contentList = message["content"] as? [[String: Any]] {
            let parts = contentList.compactMap { item -> String? in
              let type = (item["type"] as? String)?.lowercased() ?? ""
              guard type == "thinking" || type == "reasoning" else {
                return nil
              }
              if let thinking = item["thinking"] as? String, !thinking.isEmpty {
                return thinking
              }
              if let text = item["text"] as? String, !text.isEmpty {
                return text
              }
              return nil
            }
            let joined = parts.joined()
            return joined.isEmpty ? nil : joined
          }
        }
        return nil
      }

      let joined = thoughts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty {
        return joined
      }
    }

    if let reasoning = json["reasoning_content"] as? String {
      let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    return nil
  }
}

private struct StreamResponseCollector {
  private(set) var rawText: String = ""

  mutating func append(_ text: String) {
    guard !text.isEmpty else {
      return
    }

    rawText.append(text)
  }

  func previewText() -> String? {
    let normalized = rawText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !normalized.isEmpty else {
      return nil
    }

    return normalized
  }
}
