import AppKit
import XCTest

@testable import Orbe

/// 通知音サブパレットから root へ戻る往復が**落ちない**ことの回帰テスト。
///
/// ヘッダのセグメント（`headerPills`）は通知音の面だけが立て、root へ戻る `rebuild()` だけが空へ戻す。
/// カード側がその配列へ添字で読み返していると、SwiftUI は枝ごと消える `HStack` の子を古い添字のまま
/// 1 パス遅れて評価し、空配列への範囲外アクセスでプロセスごとトラップする（＝ダイアログも出ずに落ちる）。
///
/// この欠陥はモデル単体テストでは絶対に掴めない——`headerPills` が空になること自体は正しく、
/// 壊れるのは描画パスだけ。**実 `NSWindow` に本物の `PaletteCard` を載せ、実キーで戻る**ここだけが掴む。
@MainActor
final class PaletteCardHeaderPillsTests: PaletteCardWindowTestCase {
  /// 設定パレット root での通知音行（worktree の作成場所の次）。
  private let soundRow = 13

  private func model() -> SettingsPaletteModel {
    SettingsPaletteModel(
      values: ScopedSettingsValues(global: SettingsLayer()), fontNames: [], agents: ["claude"],
      localization: LocalizationStore(language: .ja))
  }

  /// 通知音サブパレットまで潜り、ヘッダのセグメントを**実際に描かせた**窓を返す。
  /// 描かせるところまでやらないと `ForEach` の子が生成されず、欠陥のあるコードでも落ちない
  /// ＝テストが何も守らなくなる。
  private func drillIntoSound(_ p: SettingsPaletteModel) -> NSWindow {
    let window = mount(p.render)
    p.render.selected = soundRow
    p.render.onActivate()
    flush(window)
    XCTAssertEqual(
      p.render.headerPills.map(\.label), ["完了", "入力待ち"], "前提: この面がヘッダのセグメントを立てている")
    return window
  }

  /// 何も変えずに実 Esc で戻る。
  func testEscapeFromNotificationSoundDoesNotCrash() {
    let p = model()
    let window = drillIntoSound(p)

    send(53, "\u{1B}", to: window)  // esc
    flush(window)

    XCTAssertTrue(p.render.headerPills.isEmpty, "root ではセグメントが消える")
    XCTAssertNil(p.render.breadcrumb, "root へ戻っている")
  }

  /// ↓↓ で試聴してから ↵ で確定して戻る（ユーザー報告の手順そのもの）。
  func testActivateAfterPreviewingDoesNotCrash() {
    let p = model()
    let window = drillIntoSound(p)

    send(125, "\u{F701}", to: window)  // ↓
    send(125, "\u{F701}", to: window)  // ↓
    flush(window)
    send(36, "\r", to: window)  // ↵（案を確定して戻る）
    flush(window)

    XCTAssertTrue(p.render.headerPills.isEmpty, "root ではセグメントが消える")
    XCTAssertNil(p.render.breadcrumb, "root へ戻っている")
  }

  /// ⇥ で試聴対象を往復させてから戻る。`active` の反転が identity を壊さないこと
  /// （id を label に置いた選択が、立て直しのたびの再マウントも identity 衝突も生まないこと）。
  func testTogglingPreviewTargetThenLeavingDoesNotCrash() {
    let p = model()
    let window = drillIntoSound(p)

    for _ in 0..<3 {
      send(48, "\t", to: window)  // ⇥
      flush(window)
    }
    XCTAssertEqual(p.render.headerPills.count, 2, "⇥ はセグメントを立て直すだけ")

    send(123, "\u{F702}", to: window)  // ←（戻る）
    flush(window)

    XCTAssertTrue(p.render.headerPills.isEmpty, "root ではセグメントが消える")
  }
}
