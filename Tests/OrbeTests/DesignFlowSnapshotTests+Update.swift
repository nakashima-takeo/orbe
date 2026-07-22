import SwiftUI
import XCTest

@testable import Orbe

/// アップデートの flow（ファイル分割の拡張）。設定›アップデートの状態カードが
/// 最新 → 確認中 → DL中(進捗) → 適用待ち → 失敗 と遷移する過程を、本物の UpdateState 遷移メソッドで
/// 駆動して撮る（visual-check の前提＝Sparkle 実体なし）。
extension DesignFlowSnapshotTests {
  func testUpdateStates() throws {
    let state = DesignSceneFixtures.updateUpToDateState()
    let settings = DesignSceneFixtures.updateSettingsModel(state)
    let size = NSSize(width: 500, height: 520)
    let l10n = LocalizationStore(language: .ja)
    try flow(
      "update_states", size: size,
      render: { paletteSnapshot(settings.render).environment(\.localization, l10n) },
      steps: [
        ("uptodate", {}),
        ("checking", { state.beginCheck() }),
        (
          "downloading",
          {
            state.beginDownload()
            state.setExpectedLength(13_000_000)
            state.receiveData(length: 8_300_000)
          }
        ),
        (
          "ready",
          {
            state.markReady(
              UpdateState.ReadyInfo(
                version: "0.2.0", notes: DesignSceneFixtures.updateSampleNotes, date: nil,
                size: 13_000_000))
          }
        ),
        ("failed", { state.fail(message: "接続に失敗しました") }),
      ])
  }
}
