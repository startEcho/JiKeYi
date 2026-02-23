import AppKit
import SwiftUI

private enum PreferencesStatusLevel {
  case info
  case success
  case error
}

enum PreferencesSection: String, CaseIterable, Identifiable {
  case services
  case models
  case ui
  case file

  var id: String { rawValue }

  var title: String {
    switch self {
    case .services:
      return "服务管理"
    case .models:
      return "模型设置"
    case .ui:
      return "快捷键与界面"
    case .file:
      return "配置文件"
    }
  }

  var subtitle: String {
    switch self {
    case .services:
      return "服务连接、术语表、路由"
    case .models:
      return "按服务独立配置模型参数"
    case .ui:
      return "快捷键、弹窗、自动化"
    case .file:
      return "路径与权限说明"
    }
  }
}

private struct GlossaryParseResult {
  let items: [GlossaryItem]
  let invalidLineNumbers: [Int]
}

@MainActor
final class PreferencesViewModel: ObservableObject {
  @Published var draft: AppSettings
  @Published var selectedServiceID: String
  @Published var statusText: String = "等待操作"
  @Published var activeSection: PreferencesSection = .services
  @Published var hasPendingChanges: Bool = false
  @Published var glossaryText: String = ""

  let settingsPath: String
  private let onSave: (AppSettings) throws -> Void
  private let onOpenSettingsFile: () -> Void

  private var statusLevel: PreferencesStatusLevel = .info
  private let glossarySeparators = ["=>", "->", "→", "：", ":", "="]

  init(
    settings: AppSettings,
    settingsPath: String,
    onSave: @escaping (AppSettings) throws -> Void,
    onOpenSettingsFile: @escaping () -> Void
  ) {
    let normalized = settings.normalized()
    self.draft = normalized
    self.selectedServiceID = normalized.resolveActiveService().id
    self.glossaryText = Self.formatGlossaryText(normalized.glossary)
    self.settingsPath = settingsPath
    self.onSave = onSave
    self.onOpenSettingsFile = onOpenSettingsFile
  }

  var statusColor: Color {
    switch statusLevel {
    case .info:
      return PrefTheme.textSecondary
    case .success:
      return PrefTheme.success
    case .error:
      return PrefTheme.danger
    }
  }

  var effectiveSummaryText: String {
    let activeService = draft.resolveActiveService().name
    let mode = draft.env.popupMode().rawValue
    let fontSize = draft.env.fontSize()
    return "当前生效：服务 \(activeService) ｜ 翻译 \(draft.env.TRANSLATE_SHORTCUT) ｜ OCR \(draft.env.OCR_TRANSLATE_SHORTCUT) ｜ 偏好设置 \(draft.env.OPEN_SETTINGS_SHORTCUT) ｜ 模式 \(mode) ｜ 字体 \(fontSize)px"
  }

  func replaceSettings(_ settings: AppSettings) {
    let normalized = settings.normalized()
    draft = normalized
    selectedServiceID = normalized.resolveActiveService().id
    glossaryText = Self.formatGlossaryText(normalized.glossary)
    hasPendingChanges = false
    setStatus("已加载", level: .info)
  }

  func markPending(_ hint: String? = nil) {
    hasPendingChanges = true
    if let hint, !hint.isEmpty {
      setStatus(hint, level: .info)
    } else {
      setStatus("有未保存修改，按 Cmd+S 或点击“保存并立即生效”", level: .info)
    }
  }

  var selectedServiceIndex: Int? {
    draft.services.firstIndex(where: { $0.id == selectedServiceID })
  }

  func addService() {
    let index = draft.services.count + 1
    let reference = draft.resolveActiveService()
    let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
    let service = ServiceConfig(
      id: "svc_\(suffix)",
      name: "服务 \(index)",
      enabled: true,
      baseUrl: reference.baseUrl,
      apiKey: "",
      model: reference.model,
      targetLanguage: reference.targetLanguage,
      timeoutMs: reference.timeoutMs,
      enableThinking: false,
      thinkingBudgetTokens: "1024",
      maxTokens: reference.maxTokens,
      temperature: reference.temperature,
      extraBodyJSON: reference.extraBodyJSON,
      enableExplanation: reference.enableExplanation,
      explanationPrompt: reference.explanationPrompt,
      enableEnglishLearning: reference.enableEnglishLearning,
      englishLearningPrompt: reference.englishLearningPrompt
    )

    draft.services.append(service)
    if !draft.bubbleVisibleServiceIds.contains(service.id) {
      draft.bubbleVisibleServiceIds.append(service.id)
    }
    selectedServiceID = service.id
    markPending("已新增服务：\(service.name)")
  }

  func removeSelectedService() {
    guard let index = selectedServiceIndex else {
      return
    }

    if draft.services.count <= 1 {
      setStatus("至少保留一个服务", level: .error)
      return
    }

    let removed = draft.services[index]
    draft.services.remove(at: index)
    draft.bubbleVisibleServiceIds.removeAll { $0 == removed.id }

    if draft.activeServiceId == removed.id {
      draft.activeServiceId = draft.services.first(where: { $0.enabled })?.id ?? draft.services[0].id
    }

    selectedServiceID = draft.activeServiceId
    normalizeBubbleVisibleServices(autoFixMessage: "已删除服务并自动调整气泡展示列表")
    markPending("已删除服务：\(removed.name)")
  }

  func setActiveService() {
    guard let selected = selectedServiceIndex.map({ draft.services[$0] }) else {
      return
    }
    draft.activeServiceId = selected.id
    if !draft.bubbleVisibleServiceIds.contains(selected.id) {
      draft.bubbleVisibleServiceIds.append(selected.id)
    }
    markPending("已设为当前服务：\(selected.name)")
  }

  func copySelectedAPIKey() {
    guard let index = selectedServiceIndex else {
      return
    }

    let value = draft.services[index].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
      setStatus("API Key 为空，无法复制", level: .error)
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
    setStatus("API Key 已复制", level: .success)
  }

  func pasteSelectedAPIKey() {
    guard let index = selectedServiceIndex else {
      return
    }

    let pasteboard = NSPasteboard.general
    let value = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if value.isEmpty {
      setStatus("粘贴失败：剪贴板为空或不可读", level: .error)
      return
    }

    draft.services[index].apiKey = value
    markPending("API Key 已粘贴")
  }

  func isBubbleServiceVisible(_ serviceID: String) -> Bool {
    draft.bubbleVisibleServiceIds.contains(serviceID)
  }

  func setBubbleServiceVisible(serviceID: String, isVisible: Bool) {
    if isVisible {
      if !draft.bubbleVisibleServiceIds.contains(serviceID) {
        draft.bubbleVisibleServiceIds.append(serviceID)
      }
      markPending()
      return
    }

    draft.bubbleVisibleServiceIds.removeAll { $0 == serviceID }
    if draft.bubbleVisibleServiceIds.isEmpty {
      normalizeBubbleVisibleServices(autoFixMessage: "气泡显示服务不能全空，已自动恢复")
      return
    }
    markPending()
  }

  func openSettingsFile() {
    onOpenSettingsFile()
  }

  func updateGlossaryText(_ text: String) {
    glossaryText = text
    markPending()
  }

  func onShortcutRecorderStatus(_ text: String, isError: Bool) {
    setStatus(text, level: isError ? .error : .info)
  }

  func save() {
    guard let serviceError = validateServices() else {
      guard let glossaryError = validateGlossary() else {
        applyAndSave()
        return
      }
      setStatus(glossaryError, level: .error)
      return
    }

    setStatus(serviceError, level: .error)
  }

  private func applyAndSave() {
    draft.activeServiceId = selectedServiceID
    let parsed = parseGlossaryText(glossaryText)
    draft.glossary = parsed.items
    normalizeBubbleVisibleServices(autoFixMessage: nil)

    let normalized = draft.normalized()

    do {
      try onSave(normalized)
      draft = normalized
      selectedServiceID = normalized.resolveActiveService().id
      glossaryText = Self.formatGlossaryText(normalized.glossary)
      hasPendingChanges = false
      setStatus("保存成功，已生效", level: .success)
    } catch {
      setStatus("保存失败：\(error.localizedDescription)", level: .error)
    }
  }

  private func validateServices() -> String? {
    if draft.services.isEmpty {
      return "至少保留一个服务"
    }

    for service in draft.services {
      let name = service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? service.id : service.name
      if service.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "服务「\(name)」缺少 Base URL"
      }
      if service.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "服务「\(name)」缺少模型名"
      }
      let timeout = Int(service.timeoutMs.trimmingCharacters(in: .whitespacesAndNewlines))
      if timeout == nil || timeout! <= 0 {
        return "服务「\(name)」超时必须是正数"
      }

      let temperature = Double(service.temperature.trimmingCharacters(in: .whitespacesAndNewlines))
      if temperature == nil || temperature! < 0 || temperature! > 2 {
        return "服务「\(name)」温度需在 0 ~ 2 之间"
      }

      let extraJSON = service.extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
      if !extraJSON.isEmpty {
        guard let data = extraJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else {
          return "服务「\(name)」附加参数 JSON 必须是对象，例如 {\"top_p\":0.9}"
        }
      }
    }

    return nil
  }

  private func validateGlossary() -> String? {
    let parsed = parseGlossaryText(glossaryText)
    if parsed.invalidLineNumbers.isEmpty {
      return nil
    }

    let preview = parsed.invalidLineNumbers.prefix(2).map(String.init).joined(separator: "、")
    return "术语表格式错误（第 \(preview) 行），请使用“原词 => 译法”"
  }

  private func normalizeBubbleVisibleServices(autoFixMessage: String?) {
    let validIDs = Set(draft.services.map(\.id))
    draft.bubbleVisibleServiceIds = draft.bubbleVisibleServiceIds
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { validIDs.contains($0) }

    if !draft.bubbleVisibleServiceIds.isEmpty {
      return
    }

    let enabled = draft.services.filter(\.enabled).map(\.id)
    if !enabled.isEmpty {
      draft.bubbleVisibleServiceIds = enabled
    } else if let first = draft.services.first?.id {
      draft.bubbleVisibleServiceIds = [first]
    }

    if let autoFixMessage {
      setStatus(autoFixMessage, level: .info)
      hasPendingChanges = true
    }
  }

  private func parseGlossaryText(_ raw: String) -> GlossaryParseResult {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    var items: [GlossaryItem] = []
    var invalidLineNumbers: [Int] = []
    var dedupe = Set<String>()

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
        continue
      }

      var parsed: GlossaryItem?
      for separator in glossarySeparators {
        guard let range = trimmed.range(of: separator) else {
          continue
        }
        let left = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !left.isEmpty, !right.isEmpty {
          parsed = GlossaryItem(source: left, target: right)
          break
        }
      }

      guard let parsed else {
        invalidLineNumbers.append(index + 1)
        continue
      }

      let key = "\(parsed.source)\u{0001}\(parsed.target)"
      if dedupe.contains(key) {
        continue
      }

      dedupe.insert(key)
      items.append(parsed)
    }

    return GlossaryParseResult(items: items, invalidLineNumbers: invalidLineNumbers)
  }

  private func setStatus(_ text: String, level: PreferencesStatusLevel) {
    statusText = text
    statusLevel = level
  }

  private static func formatGlossaryText(_ glossary: [GlossaryItem]) -> String {
    glossary.map { "\($0.source) => \($0.target)" }.joined(separator: "\n")
  }
}

private enum PrefTheme {
  static let background = Color(red: 0.06, green: 0.09, blue: 0.14)
  static let sidebar = Color(red: 0.07, green: 0.10, blue: 0.16)
  static let surface = Color(red: 0.11, green: 0.15, blue: 0.22)
  static let surfaceAlt = Color(red: 0.13, green: 0.18, blue: 0.26)
  static let input = Color(red: 0.09, green: 0.13, blue: 0.20)
  static let inputActive = Color(red: 0.14, green: 0.19, blue: 0.28)

  static let textPrimary = Color(red: 0.95, green: 0.97, blue: 1.00)
  static let textSecondary = Color(red: 0.73, green: 0.79, blue: 0.87)
  static let textMuted = Color(red: 0.62, green: 0.69, blue: 0.79)

  static let accent = Color(red: 0.28, green: 0.54, blue: 0.95)
  static let accentSoft = Color(red: 0.22, green: 0.40, blue: 0.72)
  static let success = Color(red: 0.53, green: 0.83, blue: 0.69)
  static let danger = Color(red: 0.97, green: 0.64, blue: 0.66)

  private static let fontScale: CGFloat = 0.80
  private static let fontCandidates = [
    "Microsoft YaHei",
    "MicrosoftYaHei",
    "微软雅黑",
    "PingFang SC",
    "Helvetica Neue"
  ]

  static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font(resolveFont(size: size, weight: weight, monospaced: false))
  }

  static func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font(resolveFont(size: size, weight: weight, monospaced: true))
  }

  private static func resolveFont(size: CGFloat, weight: Font.Weight, monospaced: Bool) -> NSFont {
    let scaledSize = max(11, size * fontScale)
    let nsWeight = mapWeight(weight)

    if monospaced {
      return NSFont.monospacedSystemFont(ofSize: scaledSize, weight: nsWeight)
    }

    for name in fontCandidates {
      if let base = NSFont(name: name, size: scaledSize) {
        if nsWeight.rawValue >= NSFont.Weight.semibold.rawValue {
          let converted = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
          return converted
        }
        return base
      }
    }

    return NSFont.systemFont(ofSize: scaledSize, weight: nsWeight)
  }

  private static func mapWeight(_ weight: Font.Weight) -> NSFont.Weight {
    switch weight {
    case .ultraLight:
      return .ultraLight
    case .thin:
      return .thin
    case .light:
      return .light
    case .regular:
      return .regular
    case .medium:
      return .medium
    case .semibold:
      return .semibold
    case .bold:
      return .bold
    case .heavy:
      return .heavy
    case .black:
      return .black
    default:
      return .regular
    }
  }
}

struct PreferencesView: View {
  @ObservedObject var model: PreferencesViewModel

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      content
    }
    .background(
      LinearGradient(
        colors: [PrefTheme.background, Color(red: 0.08, green: 0.11, blue: 0.17)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .frame(minWidth: 1080, minHeight: 720)
    .tint(PrefTheme.accent)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("偏好设置")
        .font(PrefTheme.font(size: 20, weight: .black))
        .foregroundStyle(PrefTheme.textPrimary)
        .padding(.bottom, 16)

      ForEach(PreferencesSection.allCases) { section in
        Button {
          model.activeSection = section
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
              .font(PrefTheme.font(size: 16, weight: .bold))
            Text(section.subtitle)
              .font(PrefTheme.font(size: 12, weight: .medium))
              .opacity(0.82)
          }
          .foregroundStyle(PrefTheme.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
        .background(model.activeSection == section ? PrefTheme.accentSoft.opacity(0.45) : Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(model.activeSection == section ? PrefTheme.accent.opacity(0.42) : Color.white.opacity(0.04), lineWidth: 0.8)
        )
        }
        .buttonStyle(.plain)
      }

      Spacer()

      if model.hasPendingChanges {
        Text("有未保存修改")
          .font(PrefTheme.font(size: 12, weight: .bold))
          .foregroundStyle(Color(red: 0.98, green: 0.89, blue: 0.72))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color(red: 0.39, green: 0.29, blue: 0.12).opacity(0.86))
          .clipShape(Capsule())
      }
    }
    .padding(18)
    .frame(width: 260)
    .frame(maxHeight: .infinity)
    .background(PrefTheme.sidebar)
    .overlay(
      Rectangle()
        .fill(Color.white.opacity(0.05))
        .frame(width: 1),
      alignment: .trailing
    )
  }

  private var content: some View {
    VStack(spacing: 0) {
      topBar
      ScrollView {
        sectionBody
          .padding(22)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Button("保存并立即生效") {
        model.save()
      }
      .buttonStyle(PrimaryButtonStyle())
      .keyboardShortcut("s", modifiers: [.command])

      Button("打开原始 JSON") {
        model.openSettingsFile()
      }
      .buttonStyle(SecondaryButtonStyle())

      Spacer(minLength: 10)

      Text(model.statusText)
        .font(PrefTheme.font(size: 14, weight: .semibold))
        .foregroundStyle(model.statusColor)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(Color.black.opacity(0.10))
  }

  @ViewBuilder
  private var sectionBody: some View {
    switch model.activeSection {
    case .services:
      servicesSection
    case .models:
      modelsSection
    case .ui:
      uiSection
    case .file:
      fileSection
    }
  }

  private var servicesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader("服务管理", "配置服务连接信息与术语表。")

      HStack(alignment: .top, spacing: 14) {
        serviceListPane
          .frame(width: 340)
        serviceConnectionPane
      }

      bubbleVisibilityPane
      glossaryPane
    }
  }

  private var modelsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader("模型设置", "按服务独立配置模型参数，每个服务只维护与自己相关的模型项。")

      HStack(alignment: .top, spacing: 14) {
        modelListPane
          .frame(width: 340)
        modelEditorPane
      }
    }
  }

  private var serviceListPane: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(model.draft.services) { service in
            Button {
              model.selectedServiceID = service.id
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(service.name.isEmpty ? "未命名服务" : service.name)
                    .font(PrefTheme.font(size: 18, weight: .bold))
                    .foregroundStyle(PrefTheme.textPrimary)
                  Spacer()
                  if service.id == model.draft.activeServiceId {
                    statusTag("当前", color: PrefTheme.accent)
                  }
                  if !service.enabled {
                    statusTag("停用", color: Color(red: 0.65, green: 0.38, blue: 0.36))
                  }
                }

                Text(service.model.isEmpty ? "(无模型)" : service.model)
                  .font(PrefTheme.font(size: 13, weight: .semibold))
                  .foregroundStyle(PrefTheme.textSecondary)
                Text(service.baseUrl.isEmpty ? "(无地址)" : service.baseUrl)
                  .font(PrefTheme.font(size: 12, weight: .medium))
                  .lineLimit(1)
                  .foregroundStyle(PrefTheme.textMuted)
              }
              .padding(14)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(model.selectedServiceID == service.id ? PrefTheme.inputActive : PrefTheme.surface)
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .stroke(model.selectedServiceID == service.id ? PrefTheme.accent.opacity(0.40) : Color.white.opacity(0.04), lineWidth: 0.8)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      HStack(spacing: 8) {
        Button("新增服务") { model.addService() }
          .buttonStyle(SecondaryButtonStyle())
        Button("删除当前") { model.removeSelectedService() }
          .buttonStyle(DangerButtonStyle())
          .disabled(model.draft.services.count <= 1)
      }
    }
    .prefCard()
  }

  private var serviceConnectionPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let index = model.selectedServiceIndex {
        let service = model.draft.services[index]

        HStack(spacing: 10) {
          Toggle("启用该服务", isOn: serviceBinding(index, \.enabled))
            .toggleStyle(SwitchToggleStyle(tint: PrefTheme.accent))
            .foregroundStyle(PrefTheme.textPrimary)

          if service.id == model.draft.activeServiceId {
            statusTag("当前生效", color: PrefTheme.accent)
          }

          Spacer(minLength: 8)

          Button("设为当前服务") {
            model.setActiveService()
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(service.id == model.draft.activeServiceId)
        }

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          labeledTextField("服务名称", binding: serviceBinding(index, \.name), placeholder: "服务名称")
          labeledTextField("接口地址 (ANTHROPIC_BASE_URL)", binding: serviceBinding(index, \.baseUrl), placeholder: "https://api.example.com")
        }

        VStack(alignment: .leading, spacing: 8) {
          fieldTitle("API Key (ANTHROPIC_AUTH_TOKEN)")
          ThemedTextField(placeholder: "请输入 API Key", text: serviceBinding(index, \.apiKey))
        }
      } else {
        Text("请先选择一个服务")
          .foregroundStyle(PrefTheme.textSecondary)
      }
    }
    .prefCard()
  }

  private var modelListPane: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(model.draft.services) { service in
            Button {
              model.selectedServiceID = service.id
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(service.name.isEmpty ? "未命名服务" : service.name)
                    .font(PrefTheme.font(size: 17, weight: .bold))
                    .foregroundStyle(PrefTheme.textPrimary)
                  Spacer()
                  if service.id == model.draft.activeServiceId {
                    statusTag("当前", color: PrefTheme.accent)
                  }
                }

                Text(service.model.isEmpty ? "(无模型)" : service.model)
                  .font(PrefTheme.font(size: 14, weight: .semibold))
                  .foregroundStyle(PrefTheme.textSecondary)

                Text(service.enabled ? "已启用" : "已停用")
                  .font(PrefTheme.font(size: 12, weight: .medium))
                  .foregroundStyle(service.enabled ? PrefTheme.textMuted : PrefTheme.danger)
              }
              .padding(14)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(model.selectedServiceID == service.id ? PrefTheme.inputActive : PrefTheme.surface)
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .stroke(model.selectedServiceID == service.id ? PrefTheme.accent.opacity(0.40) : Color.white.opacity(0.04), lineWidth: 0.8)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      Text("服务新增/删除请在“服务管理”栏目操作。")
        .font(PrefTheme.font(size: 12, weight: .semibold))
        .foregroundStyle(PrefTheme.textMuted)
    }
    .prefCard()
  }

  private var modelEditorPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let index = model.selectedServiceIndex {
        let service = model.draft.services[index]

        Text("当前服务：\(service.name.isEmpty ? service.id : service.name)")
          .font(PrefTheme.font(size: 14, weight: .bold))
          .foregroundStyle(PrefTheme.textSecondary)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          labeledTextField("模型 (ANTHROPIC_MODEL)", binding: serviceBinding(index, \.model), placeholder: "例如 MiniMax-M2.5")
          labeledTextField("目标语言 (TARGET_LANGUAGE)", binding: serviceBinding(index, \.targetLanguage), placeholder: "例如 简体中文")
          labeledTextField("超时毫秒 (API_TIMEOUT_MS)", binding: serviceBinding(index, \.timeoutMs), placeholder: "120000")
          labeledTextField("温度（0 ~ 2）", binding: serviceBinding(index, \.temperature), placeholder: "0")
        }

        subtleDivider

        Toggle(
          "展示思考过程（若上游返回）",
          isOn: serviceBinding(index, \.enableThinking)
        )
        .toggleStyle(SwitchToggleStyle(tint: PrefTheme.accent))
        .foregroundStyle(PrefTheme.textPrimary)

        subtleDivider

        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "启用原文深度讲解",
            isOn: serviceBinding(index, \.enableExplanation)
          )
          .toggleStyle(SwitchToggleStyle(tint: PrefTheme.accent))
          .foregroundStyle(PrefTheme.textPrimary)

          fieldTitle("讲解提示词（可自定义）")
          TextEditor(text: serviceBinding(index, \.explanationPrompt))
            .font(PrefTheme.font(size: 12, weight: .medium))
            .scrollContentBackground(.hidden)
            .foregroundStyle(PrefTheme.textPrimary)
            .frame(minHeight: 100)
            .padding(10)
            .background(PrefTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          Text("支持占位符：{{source}} {{translation}} {{target_language}}。留空使用默认深度讲解提示词。")
            .font(PrefTheme.font(size: 12, weight: .medium))
            .foregroundStyle(PrefTheme.textMuted)
        }

        subtleDivider

        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "启用英语学习讲解",
            isOn: serviceBinding(index, \.enableEnglishLearning)
          )
          .toggleStyle(SwitchToggleStyle(tint: PrefTheme.accent))
          .foregroundStyle(PrefTheme.textPrimary)

          fieldTitle("英语学习提示词（可自定义）")
          TextEditor(text: serviceBinding(index, \.englishLearningPrompt))
            .font(PrefTheme.font(size: 12, weight: .medium))
            .scrollContentBackground(.hidden)
            .foregroundStyle(PrefTheme.textPrimary)
            .frame(minHeight: 100)
            .padding(10)
            .background(PrefTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          Text("支持占位符：{{source}} {{translation}} {{target_language}}。留空使用默认英语学习提示词。")
            .font(PrefTheme.font(size: 12, weight: .medium))
            .foregroundStyle(PrefTheme.textMuted)
        }

        VStack(alignment: .leading, spacing: 8) {
          fieldTitle("附加请求参数 JSON（可选）")
          TextEditor(text: serviceBinding(index, \.extraBodyJSON))
            .font(PrefTheme.monoFont(size: 12, weight: .medium))
            .scrollContentBackground(.hidden)
            .foregroundStyle(PrefTheme.textPrimary)
            .frame(minHeight: 110)
            .padding(10)
            .background(PrefTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          Text("仅支持 JSON 对象，例如 {\"top_p\":0.9,\"presence_penalty\":0.2}。")
            .font(PrefTheme.font(size: 12, weight: .medium))
            .foregroundStyle(PrefTheme.textMuted)
        }
      } else {
        Text("请先选择一个服务")
          .foregroundStyle(PrefTheme.textSecondary)
      }
    }
    .prefCard()
  }

  private var bubbleVisibilityPane: some View {
    VStack(alignment: .leading, spacing: 10) {
      groupTitle("气泡模式显示结果服务")
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(model.draft.services) { item in
          Toggle(item.name.isEmpty ? item.id : item.name, isOn: bubbleVisibilityBinding(for: item.id))
            .toggleStyle(.checkbox)
            .foregroundStyle(item.enabled ? PrefTheme.textPrimary : PrefTheme.textMuted)
            .disabled(!item.enabled)
        }
      }

      Text("仅在 bubble 模式生效。至少保留一个可见服务，避免气泡空白。")
        .font(PrefTheme.font(size: 13, weight: .medium))
        .foregroundStyle(PrefTheme.textMuted)
    }
    .prefCard()
  }

  private var glossaryPane: some View {
    VStack(alignment: .leading, spacing: 10) {
      groupTitle("术语表（每行：原词 => 译法）")
      TextEditor(text: Binding(
        get: { model.glossaryText },
        set: { model.updateGlossaryText($0) }
      ))
      .font(PrefTheme.monoFont(size: 13, weight: .medium))
      .scrollContentBackground(.hidden)
      .foregroundStyle(PrefTheme.textPrimary)
      .frame(minHeight: 220)
      .padding(10)
      .background(PrefTheme.input)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text("支持分隔符：=> / -> / = / : / ：。空行与注释行（# 或 //）会忽略。")
        .font(PrefTheme.font(size: 13, weight: .medium))
        .foregroundStyle(PrefTheme.textMuted)
    }
    .prefCard()
  }

  private var uiSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader("快捷键与界面", "快捷键支持点击录制后自动识别组合键；修改后保存立即生效。")

      VStack(alignment: .leading, spacing: 12) {
        ShortcutCaptureControl(
          title: "TRANSLATE_SHORTCUT",
          hint: "触发翻译选中文本",
          value: Binding(
            get: { model.draft.env.TRANSLATE_SHORTCUT },
            set: {
              model.draft.env.TRANSLATE_SHORTCUT = $0
              model.markPending()
            }
          ),
          onStatusChange: model.onShortcutRecorderStatus
        )

        ShortcutCaptureControl(
          title: "OPEN_SETTINGS_SHORTCUT",
          hint: "打开偏好设置窗口",
          value: Binding(
            get: { model.draft.env.OPEN_SETTINGS_SHORTCUT },
            set: {
              model.draft.env.OPEN_SETTINGS_SHORTCUT = $0
              model.markPending()
            }
          ),
          onStatusChange: model.onShortcutRecorderStatus
        )

        ShortcutCaptureControl(
          title: "OCR_TRANSLATE_SHORTCUT",
          hint: "框选截图并执行 OCR 翻译",
          value: Binding(
            get: { model.draft.env.OCR_TRANSLATE_SHORTCUT },
            set: {
              model.draft.env.OCR_TRANSLATE_SHORTCUT = $0
              model.markPending()
            }
          ),
          onStatusChange: model.onShortcutRecorderStatus
        )

        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            fieldTitle("POPUP_MODE")
            HStack(spacing: 8) {
              modeButton(title: "panel", mode: .panel)
              modeButton(title: "bubble", mode: .bubble)
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            fieldTitle("TRANSLATOR_FONT_SIZE")
            HStack(spacing: 8) {
              Button("-") {
                let next = max(12, model.draft.env.fontSize() - 1)
                model.draft.env.TRANSLATOR_FONT_SIZE = String(next)
                model.markPending()
              }
              .buttonStyle(SecondaryButtonStyle(small: true))

              Text("\(model.draft.env.fontSize()) px")
                .font(PrefTheme.font(size: 16, weight: .bold))
                .foregroundStyle(PrefTheme.textPrimary)
                .frame(minWidth: 72)

              Button("+") {
                let next = min(32, model.draft.env.fontSize() + 1)
                model.draft.env.TRANSLATOR_FONT_SIZE = String(next)
                model.markPending()
              }
              .buttonStyle(SecondaryButtonStyle(small: true))
            }
          }

          Spacer(minLength: 0)
        }

        Text("快捷键录制说明：点击“开始录制”后直接按组合键；Delete/Backspace 清空，Esc 取消。")
          .font(PrefTheme.font(size: 13, weight: .medium))
          .foregroundStyle(PrefTheme.textMuted)

        Toggle(
          "思考内容默认展开",
          isOn: Binding(
            get: { model.draft.env.THINKING_DEFAULT_EXPANDED },
            set: {
              model.draft.env.THINKING_DEFAULT_EXPANDED = $0
              model.markPending()
            }
          )
        )
        .toggleStyle(SwitchToggleStyle(tint: PrefTheme.accent))
        .foregroundStyle(PrefTheme.textPrimary)
      }
      .prefCard()

      VStack(alignment: .leading, spacing: 10) {
        groupTitle("自动化处理")
        automationToggle(
          title: "将翻译原文的换行符替换为空格",
          note: "适合 OCR / PDF 断行较多文本。",
          binding: automationBinding(\.replaceLineBreaksWithSpace)
        )
        automationToggle(
          title: "将翻译原文中的注释符号（/* */ // #）去掉",
          note: "仅做轻量清洗，不改动语义。",
          binding: automationBinding(\.stripCodeCommentMarkers)
        )
        automationToggle(
          title: "将翻译原文中的“- 空格”断词连接回去",
          note: "示例：insignif- icant -> insignificant。",
          binding: automationBinding(\.removeHyphenSpace)
        )
        automationToggle(
          title: "自动复制截图翻译 OCR 结果",
          note: "当前版本预留，接入 OCR 流程后自动生效。",
          binding: automationBinding(\.autoCopyOcrResult)
        )
        automationToggle(
          title: "自动复制首个翻译结果",
          note: "每次任务只自动复制一次。",
          binding: automationBinding(\.autoCopyFirstResult)
        )
        automationToggle(
          title: "点击译文中的英文单词时自动复制",
          note: "点击译文卡片时会自动复制命中的英文单词。",
          binding: automationBinding(\.copyHighlightedWordOnClick)
        )
        automationToggle(
          title: "自动播放翻译原文",
          note: "使用系统语音播放待翻译文本。",
          binding: automationBinding(\.autoPlaySourceText)
        )
      }
      .prefCard()

      Text(model.effectiveSummaryText)
        .font(PrefTheme.font(size: 13, weight: .semibold))
        .foregroundStyle(PrefTheme.textSecondary)
        .padding(.horizontal, 4)
    }
  }

  private var fileSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader("配置文件", "支持直接打开 JSON 手工编辑，保存后即时生效。")

      VStack(alignment: .leading, spacing: 12) {
        groupTitle("设置文件路径")
        Text(model.settingsPath)
          .font(PrefTheme.monoFont(size: 14, weight: .medium))
          .foregroundStyle(Color(red: 0.58, green: 0.86, blue: 0.96))
          .textSelection(.enabled)

        subtleDivider

        groupTitle("权限提示")
        Text("要读取选中文本并触发复制兜底，需要在 系统设置 > 隐私与安全性 > 辅助功能 中允许本应用。若使用截图 OCR，还需在“屏幕录制”中允许本应用。")
          .font(PrefTheme.font(size: 14, weight: .medium))
          .foregroundStyle(PrefTheme.textSecondary)
      }
      .prefCard()
    }
  }

  private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(PrefTheme.font(size: 34, weight: .black))
        .foregroundStyle(PrefTheme.textPrimary)
      Text(subtitle)
        .font(PrefTheme.font(size: 15, weight: .semibold))
        .foregroundStyle(PrefTheme.textSecondary)
    }
  }

  private func groupTitle(_ text: String) -> some View {
    Text(text)
      .font(PrefTheme.font(size: 22, weight: .black))
      .foregroundStyle(PrefTheme.textPrimary)
  }

  private func fieldTitle(_ text: String) -> some View {
    Text(text)
      .font(PrefTheme.font(size: 15, weight: .bold))
      .foregroundStyle(PrefTheme.textSecondary)
  }

  private func statusTag(_ text: String, color: Color) -> some View {
    Text(text)
      .font(PrefTheme.font(size: 12, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(color.opacity(0.90))
      .clipShape(Capsule())
  }

  private func modeButton(title: String, mode: PopupMode) -> some View {
    Button {
      model.draft.env.POPUP_MODE = mode.rawValue
      model.markPending()
    } label: {
      Text(title)
        .font(PrefTheme.font(size: 14, weight: .bold))
        .foregroundStyle(PrefTheme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(model.draft.env.popupMode() == mode ? PrefTheme.accentSoft : PrefTheme.input)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(model.draft.env.popupMode() == mode ? PrefTheme.accent.opacity(0.46) : Color.white.opacity(0.05), lineWidth: 0.8)
        )
    }
    .buttonStyle(.plain)
  }

  private var subtleDivider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.10))
      .frame(height: 1)
  }

  private func labeledTextField(_ title: String, binding: Binding<String>, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      fieldTitle(title)
      ThemedTextField(placeholder: placeholder, text: binding)
    }
  }

  private func automationToggle(title: String, note: String, binding: Binding<Bool>) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Toggle("", isOn: binding)
        .labelsHidden()
        .toggleStyle(SwitchToggleStyle(tint: PrefTheme.accent))

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(PrefTheme.font(size: 14, weight: .bold))
          .foregroundStyle(PrefTheme.textPrimary)
        Text(note)
          .font(PrefTheme.font(size: 12, weight: .medium))
          .foregroundStyle(PrefTheme.textMuted)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }

  private func serviceBinding(_ index: Int, _ keyPath: WritableKeyPath<ServiceConfig, String>) -> Binding<String> {
    Binding(
      get: { model.draft.services[index][keyPath: keyPath] },
      set: { newValue in
        model.draft.services[index][keyPath: keyPath] = newValue
        model.markPending()
      }
    )
  }

  private func serviceBinding(_ index: Int, _ keyPath: WritableKeyPath<ServiceConfig, Bool>) -> Binding<Bool> {
    Binding(
      get: { model.draft.services[index][keyPath: keyPath] },
      set: { newValue in
        model.draft.services[index][keyPath: keyPath] = newValue
        model.markPending()
      }
    )
  }

  private func automationBinding(_ keyPath: WritableKeyPath<AutomationSettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { model.draft.automation[keyPath: keyPath] },
      set: { newValue in
        model.draft.automation[keyPath: keyPath] = newValue
        model.markPending()
      }
    )
  }

  private func bubbleVisibilityBinding(for serviceID: String) -> Binding<Bool> {
    Binding(
      get: { model.isBubbleServiceVisible(serviceID) },
      set: { isVisible in
        model.setBubbleServiceVisible(serviceID: serviceID, isVisible: isVisible)
      }
    )
  }
}

private struct ThemedTextField: View {
  let placeholder: String
  @Binding var text: String

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(PrefTheme.font(size: 16, weight: .semibold))
      .foregroundStyle(PrefTheme.textPrimary)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(PrefTheme.input)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
      )
  }
}

private struct ShortcutCaptureControl: View {
  let title: String
  let hint: String
  @Binding var value: String
  let onStatusChange: (String, Bool) -> Void

  @StateObject private var recorder = ShortcutRecorderState()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(PrefTheme.font(size: 15, weight: .bold))
        .foregroundStyle(PrefTheme.textSecondary)

      HStack(spacing: 8) {
        Button {
          toggleRecording()
        } label: {
          Text(value.isEmpty ? "点击这里开始录制" : value)
            .font(PrefTheme.monoFont(size: 16, weight: .bold))
            .foregroundStyle(PrefTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(recorder.isRecording ? PrefTheme.inputActive : PrefTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(recorder.isRecording ? PrefTheme.accent.opacity(0.58) : Color.white.opacity(0.05), lineWidth: 0.8)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)

        Button(recorder.isRecording ? "按组合键..." : "开始录制") {
          toggleRecording()
        }
        .buttonStyle(SecondaryButtonStyle())

        Button("清空") {
          value = ""
          onStatusChange("快捷键已清空，可直接保存", false)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(value.isEmpty)
      }

      Text(hint)
        .font(PrefTheme.font(size: 13, weight: .medium))
        .foregroundStyle(PrefTheme.textMuted)
    }
    .padding(12)
    .background(PrefTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onDisappear {
      recorder.stop()
    }
  }

  private func toggleRecording() {
    if recorder.isRecording {
      recorder.stop(status: "已取消录制", isError: false)
    } else {
      recorder.start(value: $value, onStatusChange: onStatusChange)
    }
  }
}

@MainActor
private final class ShortcutRecorderState: ObservableObject {
  @Published var isRecording = false

  private var monitor: Any?
  private var value: Binding<String>?
  private var onStatusChange: ((String, Bool) -> Void)?

  func start(value: Binding<String>, onStatusChange: @escaping (String, Bool) -> Void) {
    stop()
    self.value = value
    self.onStatusChange = onStatusChange
    self.isRecording = true
    onStatusChange("录制中：请按下快捷键组合", false)

    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self else {
        return event
      }
      return self.handle(event)
    }
  }

  func stop(status: String? = nil, isError: Bool = false) {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    isRecording = false

    if let status {
      onStatusChange?(status, isError)
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard isRecording else {
      return event
    }

    if event.keyCode == 53 {
      stop(status: "已取消录制", isError: false)
      return nil
    }

    if event.keyCode == 51 || event.keyCode == 117 {
      value?.wrappedValue = ""
      stop(status: "快捷键已清空，可直接保存", isError: false)
      return nil
    }

    if ShortcutAcceleratorParser.isModifierOnly(event) {
      onStatusChange?("请继续按下主键（如 T / O / F1）", false)
      return nil
    }

    guard let accelerator = ShortcutAcceleratorParser.accelerator(from: event) else {
      onStatusChange?("无效组合：请至少包含修饰键 + 主键", true)
      return nil
    }

    value?.wrappedValue = accelerator
    stop(status: "已录入：\(accelerator)", isError: false)
    return nil
  }
}

private enum ShortcutAcceleratorParser {
  private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 60, 58, 61, 59, 62]

  static func isModifierOnly(_ event: NSEvent) -> Bool {
    modifierKeyCodes.contains(event.keyCode)
  }

  static func accelerator(from event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: [String] = []

    if flags.contains(.command) || flags.contains(.control) {
      modifiers.append("CommandOrControl")
    }
    if flags.contains(.option) {
      modifiers.append("Alt")
    }
    if flags.contains(.shift) {
      modifiers.append("Shift")
    }

    guard !modifiers.isEmpty else {
      return nil
    }

    guard let key = keyToken(from: event) else {
      return nil
    }

    return (modifiers + [key]).joined(separator: "+")
  }

  private static func keyToken(from event: NSEvent) -> String? {
    let keyCode = event.keyCode

    let namedMap: [UInt16: String] = [
      36: "Enter",
      48: "Tab",
      49: "Space",
      53: "Esc",
      115: "Home",
      116: "PageUp",
      117: "Delete",
      119: "End",
      121: "PageDown",
      122: "F1",
      120: "F2",
      99: "F3",
      118: "F4",
      96: "F5",
      97: "F6",
      98: "F7",
      100: "F8",
      101: "F9",
      109: "F10",
      103: "F11",
      111: "F12",
      123: "Left",
      124: "Right",
      125: "Down",
      126: "Up",
      82: "num0",
      83: "num1",
      84: "num2",
      85: "num3",
      86: "num4",
      87: "num5",
      88: "num6",
      89: "num7",
      91: "num8",
      92: "num9",
      69: "numadd",
      78: "numsub",
      67: "nummult",
      75: "numdiv",
      65: "numdec",
      76: "numEnter"
    ]

    if let named = namedMap[keyCode] {
      return named
    }

    let symbolMap: [UInt16: String] = [
      24: "=",
      27: "-",
      30: "]",
      33: "[",
      39: "'",
      41: ";",
      42: "\\",
      43: ",",
      44: "/",
      47: ".",
      50: "`"
    ]

    if let symbol = symbolMap[keyCode] {
      return symbol
    }

    guard let chars = event.charactersIgnoringModifiers?.uppercased(), chars.count == 1 else {
      return nil
    }

    guard let scalar = chars.unicodeScalars.first?.value else {
      return nil
    }

    let isDigit = (48 ... 57).contains(scalar)
    let isUpperLetter = (65 ... 90).contains(scalar)
    return (isDigit || isUpperLetter) ? chars : nil
  }
}

private extension View {
  func prefCard() -> some View {
    self
      .padding(14)
      .background(PrefTheme.surface)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

private struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(PrefTheme.font(size: 14, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(configuration.isPressed ? PrefTheme.accent.opacity(0.75) : PrefTheme.accent)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

private struct SecondaryButtonStyle: ButtonStyle {
  var small = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(PrefTheme.font(size: small ? 13 : 14, weight: .semibold))
      .foregroundStyle(PrefTheme.textPrimary)
      .padding(.horizontal, small ? 10 : 12)
      .padding(.vertical, small ? 7 : 9)
      .background(configuration.isPressed ? PrefTheme.inputActive : PrefTheme.input)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
      )
  }
}

private struct DangerButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(PrefTheme.font(size: 14, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(configuration.isPressed ? Color(red: 0.56, green: 0.26, blue: 0.25) : Color(red: 0.66, green: 0.31, blue: 0.30))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
