import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
  let viewModel: PreferencesViewModel

  init(
    settings: AppSettings,
    settingsPath: String,
    onSave: @escaping (AppSettings) throws -> Void,
    onOpenSettingsFile: @escaping () -> Void
  ) {
    self.viewModel = PreferencesViewModel(
      settings: settings,
      settingsPath: settingsPath,
      onSave: onSave,
      onOpenSettingsFile: onOpenSettingsFile
    )

    let hosting = NSHostingController(rootView: PreferencesView(model: viewModel))
    let window = NSWindow(contentViewController: hosting)
    window.title = ""
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isOpaque = true
    window.backgroundColor = NSColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 1.0)
    if #available(macOS 11.0, *) {
      window.toolbarStyle = .unifiedCompact
      window.titlebarSeparatorStyle = .none
    }
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 1080, height: 720)
    window.center()
    window.setFrameAutosaveName("JiKeYiTransPreferencesWindow")

    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func refresh(_ settings: AppSettings) {
    viewModel.replaceSettings(settings)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
}
