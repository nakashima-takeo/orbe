import SwiftUI
import XCTest

@testable import Orbe

/// アップデート UI の gallery（見本 UpdateCheckDoc 2a–2d 突合用）。Sparkle 実体なしで UpdateState を
/// 注入し、トースト（右下・340px）・変更内容シート（中央 450px）・設定›アップデートの状態カード
/// 5 状態を撮る（+WorkspaceCreate と同じくファイル分割の拡張）。
extension DesignGallerySnapshotTests {
  func renderUpdateSnapshots(dir: URL) throws {
    let stage = NSSize(width: 640, height: 520)
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

    // 2b 変更内容シート（scrim ごと）。
    try writePNG(
      ZStack {
        BackgroundGlow()
        UpdateChangesOverlay(model: DesignSceneFixtures.updateReadyState())
      }
      .frame(width: stage.width, height: stage.height)
      .environment(\.localization, l10n),
      size: stage, name: "update_changes.png", dir: dir)

    // 2c/2d 設定›アップデート（状態カード 5 状態）。
    let cases: [(String, UpdateState)] = [
      ("ready", DesignSceneFixtures.updateReadyState()),
      ("checking", DesignSceneFixtures.updateCheckingState()),
      ("downloading", DesignSceneFixtures.updateDownloadingState()),
      ("uptodate", DesignSceneFixtures.updateUpToDateState()),
      ("failed", DesignSceneFixtures.updateFailedState()),
    ]
    for (name, state) in cases {
      let model = DesignSceneFixtures.updateSettingsModel(state)
      try writePNG(
        paletteSnapshot(model.render).environment(\.localization, l10n),
        size: NSSize(width: 500, height: 520), name: "update_settings_\(name).png", dir: dir)
    }
  }
}
