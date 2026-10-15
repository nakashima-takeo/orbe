import Foundation

/// diff の見せ方（インライン / 並列）。アプリ全体で 1 つ（どの diff タブにも効く）で、app-state に永続する。
@MainActor @Observable
final class EditorDiffModeState {
  private(set) var mode: EditorDiff.Mode
  @ObservationIgnored private let persists: Bool

  init(mode: EditorDiff.Mode = .inline, persists: Bool = false) {
    self.mode = mode
    self.persists = persists
  }

  /// app-state から起こす（以後の変更は書き戻す）。読めない値・欠落はインライン。
  static func loaded() -> EditorDiffModeState {
    EditorDiffModeState(
      mode: AppStatePersistence.load()?.editorDiffMode?.mode.flatMap(EditorDiff.Mode.init)
        ?? .inline,
      persists: true)
  }

  func select(_ mode: EditorDiff.Mode) {
    guard mode != self.mode else { return }
    self.mode = mode
    guard persists else { return }
    AppStatePersistence.update { $0.editorDiffMode = EditorDiffModeRecord(mode: mode.rawValue) }
  }
}
