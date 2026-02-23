import Foundation

final class SettingsStore {
  private let fileManager: FileManager
  let configDirectoryURL: URL
  let settingsURL: URL
  let stateURL: URL

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let homeURL = fileManager.homeDirectoryForCurrentUser
    self.configDirectoryURL = homeURL.appendingPathComponent(".jikeyi-trans", isDirectory: true)
    self.settingsURL = configDirectoryURL.appendingPathComponent("settings.json")
    self.stateURL = homeURL.appendingPathComponent(".jikeyi-trans.json")
  }

  func load() throws -> AppSettings {
    try ensureFiles()

    let data = try Data(contentsOf: settingsURL)
    let decoder = JSONDecoder()
    let decoded = (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings.default
    let normalized = decoded.normalized()

    if normalized != decoded {
      try save(normalized)
    }

    return normalized
  }

  func save(_ settings: AppSettings) throws {
    try ensureFiles()
    let normalized = settings.normalized()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(normalized)
    try data.write(to: settingsURL, options: .atomic)
  }

  private func ensureFiles() throws {
    if !fileManager.fileExists(atPath: configDirectoryURL.path) {
      try fileManager.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
    }

    if !fileManager.fileExists(atPath: settingsURL.path) {
      try save(AppSettings.default)
    }

    if !fileManager.fileExists(atPath: stateURL.path) {
      let stateData = try JSONSerialization.data(
        withJSONObject: ["hasCompletedOnboarding": true],
        options: [.prettyPrinted, .sortedKeys]
      )
      try stateData.write(to: stateURL, options: .atomic)
    }
  }
}
