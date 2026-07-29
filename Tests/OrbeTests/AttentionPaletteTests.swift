import XCTest

@testable import Orbe

/// Attention パレットが**開いたまま**行の差し替えを受ける（`flushChrome` の snapshot 更新が
/// `setRows` で流し込む）ときの選択の扱いを固定する。並びは stateChangedAt 降順なので、
/// 表示中に別ペインが waiting / done へ変われば行は先頭へ挿し込まれ、index は総ずれする。
@MainActor
final class AttentionPaletteTests: XCTestCase {

  private func row(_ paneId: Int, at offset: TimeInterval) -> AttentionRow {
    AttentionRow(
      paneId: paneId, workspaceName: "ws\(paneId)", tabTitle: "tab", state: "waiting",
      message: nil, stateChangedAt: Date().addingTimeInterval(offset))
  }

  /// 行が先頭に挿し込まれても、選択は**同じペイン**に留まる（index を据え置かない）。
  /// これを外すと ↵ が「選んだ覚えのない別ペイン」へ飛び、その端末に打鍵が入る。
  func testSelectionFollowsPaneWhenRowsShift() {
    let model = AttentionPaletteModel()
    model.setRows([row(1, at: -10), row(2, at: -20)])
    model.render.selected = 1  // ペイン 2 を選ぶ

    // ペイン 3 が新たに waiting になり、降順で先頭へ入る（1 → index 1、2 → index 2）。
    model.setRows([row(3, at: 0), row(1, at: -10), row(2, at: -20)])
    XCTAssertEqual(model.render.selected, 2, "選択は index でなくペイン 2 に追随する")

    var focused: Int?
    model.onFocusPane = { focused = $0 }
    model.activate()
    XCTAssertEqual(focused, 2, "↵ は選んだままのペインへ飛ぶ")
  }

  /// 選択していたペインが一覧から消えたら（idle 化・clear・閉じた）範囲へ丸める。
  func testSelectionClampsWhenSelectedPaneDisappears() {
    let model = AttentionPaletteModel()
    model.setRows([row(1, at: -10), row(2, at: -20), row(3, at: -30)])
    model.render.selected = 2  // ペイン 3

    model.setRows([row(1, at: -10)])
    XCTAssertEqual(model.render.selected, 0)
  }

  /// 追い直しはモダリティを奪わない——ポインタ操作中に裏で行が動いても、ホバー追従が切れない。
  func testRestoreKeepsPointerModality() {
    let model = AttentionPaletteModel()
    model.setRows([row(1, at: -10), row(2, at: -20)])
    model.render.inputModality = .pointer
    model.render.hoverSelect(1)

    model.setRows([row(3, at: 0), row(1, at: -10), row(2, at: -20)])
    XCTAssertEqual(model.render.inputModality, .pointer, "裏の差し替えで .keyboard へ戻さない")
    model.render.hoverSelect(0)
    XCTAssertEqual(model.render.selected, 0, "ホバー追従が生きたまま")
  }
}
