import AppKit
import OrbeSound
import XCTest

@testable import Orbe

/// 通知音サブパレットから root へ戻る往復が**落ちない**ことの回帰テスト。
///
/// リスト直上のセグメント（`segments`）は通知音の面だけが立て、root へ戻る `rebuild()` だけが空へ戻す。
/// カード側がその配列へ添字で読み返していると、SwiftUI は枝ごと消える `HStack` の子を古い添字のまま
/// 1 パス遅れて評価し、空配列への範囲外アクセスでプロセスごとトラップする（＝ダイアログも出ずに落ちる）。
///
/// この欠陥はモデル単体テストでは絶対に掴めない——`segments` が空になること自体は正しく、
/// 壊れるのは描画パスだけ。**実 `NSWindow` に本物の `PaletteCard` を載せ、実キーで戻る**ここだけが掴む。
@MainActor
final class PaletteCardSegmentsTests: PaletteCardWindowTestCase {
  /// 設定パレット root での通知音行（worktree の作成場所の次）。
  private let soundRow = 12

  private func model() -> SettingsPaletteModel {
    SettingsPaletteModel(
      values: ScopedSettingsValues(global: SettingsLayer()), fontNames: [], agents: ["claude"],
      localization: LocalizationStore(language: .ja))
  }

  /// 通知音サブパレットまで潜り、リスト直上のセグメントを**実際に描かせた**窓を返す。
  /// 描かせるところまでやらないと `ForEach` の子が生成されず、欠陥のあるコードでも落ちない
  /// ＝テストが何も守らなくなる。
  private func drillIntoSound(_ p: SettingsPaletteModel) -> NSWindow {
    let window = mount(p.render)
    p.render.selected = soundRow
    p.render.onActivate()
    flush(window)
    XCTAssertEqual(
      p.render.segments.map(\.label), ["完了", "入力待ち"], "前提: この面がリスト直上のセグメントを立てている")
    return window
  }

  /// ↓↓ で試聴してから ↵ で確定して戻る（ユーザー報告の手順そのもの）。
  func testActivateAfterPreviewingDoesNotCrash() {
    let p = model()
    let window = drillIntoSound(p)

    let startRow = p.render.selected
    send(125, "\u{F701}", to: window)  // ↓
    send(125, "\u{F701}", to: window)  // ↓
    flush(window)
    // 選択は enabled 行を巡回する（→ `PaletteModel.move`）ので、既定の音案が末尾でも成り立つ。
    XCTAssertEqual(
      p.render.selected, (startRow + 2) % p.render.rows.count, "↓↓ が届いて試聴行が 2 行進んだ")

    send(36, "\r", to: window)  // ↵（案を確定して戻る）
    flush(window)

    XCTAssertTrue(p.render.segments.isEmpty, "root ではセグメントが消える")
    XCTAssertNil(p.render.breadcrumb, "root へ戻っている")
  }
}
