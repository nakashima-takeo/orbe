import SwiftUI
import XCTest

@testable import Orbe

/// アップデート UI の gallery（見本 UpdateCheckDoc 2a–2d 突合用）。Sparkle 実体なしで UpdateState を
/// 注入し、トースト（右下・340px）・変更内容シート（中央 450px）・設定›アップデートの状態カード
/// 5 状態と「今すぐ確認」行の実行不可 2 態を撮る（+WorkspaceCreate と同じくファイル分割の拡張）。
extension DesignGallerySnapshotTests {
  private var updateStage: NSSize { NSSize(width: 640, height: 520) }

  func renderUpdateSnapshots(dir: URL) throws {
    try renderUpdateToastAndChanges(dir: dir)
    try renderUpdateSettingsSnapshots(dir: dir)
  }

  /// 2a トーストと 2b 変更内容シート（既定ノートとノートの形が変わる 3 種）。
  private func renderUpdateToastAndChanges(dir: URL) throws {
    let stage = updateStage
    let l10n = LocalizationStore(language: .ja)

    // 2a トースト（design 正典 ステージ同寸・右下 16px）。
    try writePNG(
      ZStack(alignment: .bottomTrailing) {
        BackgroundGlow()
        UpdateToastView(state: DesignSceneFixtures.updateReadyState())
          .padding(Theme.Space.bar)
      }
      .frame(width: stage.width, height: stage.height)
      .environment(\.localization, l10n),
      size: stage, name: "update_toast.png", dir: dir)

    // 2b 変更内容シート（scrim ごと）。既定ノートに続けて、項目の多いノート（窓に収まりボタンが
    // 見える／溢れは内部スクロール）、「修正」だけのノート（分類が見出しの語で決まる）、
    // 規約外の見出しと見出し無し（中立の `•`）。
    let noteCases: [(String, String)] = [
      ("update_changes.png", DesignSceneFixtures.updateSampleNotes),
      ("update_changes_long.png", DesignSceneFixtures.updateLongSampleNotes),
      ("update_changes_fix_only.png", DesignSceneFixtures.updateFixOnlyNotes),
      ("update_changes_neutral.png", DesignSceneFixtures.updateNeutralNotes),
    ]
    for (name, notes) in noteCases {
      try writePNG(
        ZStack {
          BackgroundGlow()
          UpdateChangesOverlay(model: DesignSceneFixtures.updateReadyState(notes: notes))
        }
        .frame(width: stage.width, height: stage.height)
        .environment(\.localization, l10n),
        size: stage, name: name, dir: dir)
    }
  }

  /// 2c/2d 設定›アップデート（状態カード 5 状態＋「今すぐ確認」行の実行不可 2 態）。
  /// 適用待ちは行が器の高さ上限を超えるため、「今すぐ確認」行を選択した状態＝その行が見えている
  /// スクロール位置で撮る（減光を見るには行が見えている必要がある）。
  private func renderUpdateSettingsSnapshots(dir: URL) throws {
    let l10n = LocalizationStore(language: .ja)
    let cases: [(String, SettingsPaletteModel)] = [
      ("ready", DesignSceneFixtures.updateSettingsModel(DesignSceneFixtures.updateReadyState())),
      (
        "checking",
        DesignSceneFixtures.updateSettingsModel(DesignSceneFixtures.updateCheckingState())
      ),
      (
        "downloading",
        DesignSceneFixtures.updateSettingsModel(DesignSceneFixtures.updateDownloadingState())
      ),
      (
        "uptodate",
        DesignSceneFixtures.updateSettingsModel(DesignSceneFixtures.updateUpToDateState())
      ),
      ("failed", DesignSceneFixtures.updateSettingsModel(DesignSceneFixtures.updateFailedState())),
      // 「今すぐ確認」行の実行不可 2 態（減光 / 背景確認中のスピナー）。
      (
        "ready_busy",
        DesignSceneFixtures.updateSettingsModel(
          DesignSceneFixtures.updateReadyBusyState(), selectCheckNow: true)
      ),
      (
        "background_checking",
        DesignSceneFixtures.updateSettingsModel(DesignSceneFixtures.updateBackgroundCheckingState())
      ),
    ]
    for (name, model) in cases {
      try writePNG(
        paletteSnapshot(model.render).environment(\.localization, l10n),
        size: NSSize(width: 500, height: 520), name: "update_settings_\(name).png", dir: dir)
    }
  }
}
