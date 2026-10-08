import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 主と点で受ける入口の境——入力欄の選択のドラッグ・字の位置の問い・入力欄の横の外へのドラッグ・入力欄を閉じる知らせ・
/// 焦点の変化・入力欄へ落とすファイル。壊れると、返信欄の選択をドラッグして本文の字が動く・変換中のクリックを IME に
/// 取られる・返信欄のドラッグで本文が横に流れる・返信欄を畳んでも区画が古い高さで並ぶ・焦点の無い窓で返信欄のキャレット
/// が点滅し続ける・返信欄にファイルを落として別の文書が開く。
extension SurfaceZonesTests {
  /// 入力欄の場の文の位置 `offset` のすぐ右の点（view の座標）。
  private func fieldPoint(_ site: EditingSite, _ offset: Int) throws -> CGPoint {
    let rect = site.textRect(
      NSRange(location: offset, length: 0), row: 0, try XCTUnwrap(site.editingEnvironment()),
      marked: nil)
    return CGPoint(x: rect.minX + 0.5, y: rect.midY)
  }

  /// 入力欄の選択の上を押してドラッグしても運ばず（本文の選択も運ばない）、押した所から選び直す。
  func testDraggingFromAFieldSelectionReselectsInTheField() throws {
    let setup = try threaded()
    let (opened, field) = (setup.opened, setup.field)
    let surface = opened.surface
    surface.selectedRange = NSRange(location: 0, length: 5)
    surface.focus(field)
    surface.textView.insertText("abcdefghij")
    surface.textView.selectAll(nil)
    let site = try XCTUnwrap(surface.fields["reply"])
    let body = text(opened.document)
    try mouse(opened, .leftMouseDown, at: try fieldPoint(site, 2))
    try mouse(opened, .leftMouseDragged, at: try fieldPoint(site, 6))
    try mouse(opened, .leftMouseUp, at: try fieldPoint(site, 6))
    XCTAssertEqual(site.editor.state.cursors.primary.selection, NSRange(location: 2, length: 4))
    XCTAssertEqual(field.string, "abcdefghij")
    XCTAssertEqual(text(opened.document), body, "本文は変わらない")
    XCTAssertEqual(surface.editor.state.cursors.primary.selection, NSRange(location: 0, length: 5))
  }
}
