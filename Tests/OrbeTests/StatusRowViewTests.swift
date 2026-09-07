import SwiftUI
import XCTest

@testable import Orbe

/// タブ行 View の判断ロジック——描くセグメント列の既定、ドラッグ並び替えの挿入先・追従・キャレット、
/// 掴み状態の遷移（破棄と commit）。`StatusRowView` の非描画関数を、掴み開始時に固定する幾何
/// （`StatusTabLayout.geometry`）を与えて直接呼ぶ。
///
/// 壊れると何が起きるか。セルの挿入先がセグメント端で止まらないと、`onReorder` が store に弾かれて
/// 「掴めるのに落とせない」操作になり、キャレットは落ちない場所を指す。挿入前 index 基準がずれると
/// 右へ 1 段の移動が no-op になるか、1 つ飛びに落ちる。追従クランプが外れるとセルが器の外へ
/// はみ出して描かれる。segments の既定が単独に落ちないと、流し込まないホスト（gallery）で
/// 全タブが 1 本の連に描かれる。
@MainActor
final class StatusRowViewTests: OrbeTestCase {

  private let gap = Chrome.tabGap
  private let bar = DSSegmentBar.width

  /// 幅 100 のセル 6 枚: 連 [0,1,2]（バー）・単独 [3]・連 [4,5]（バー）。
  /// x: セル bar,bar+100,bar+200 ｜ 連 0 = 0…bar+300 ｜ 単独 3 = そこから +gap の 100 幅
  /// ｜ 連 2 = そのさらに +gap から bar+200 幅。
  private var geometry: StatusTabLayout.Geometry {
    StatusTabLayout.geometry(
      widths: Array(repeating: 100, count: 6), segments: [0..<3, 3..<4, 4..<6])
  }

  private func session(
    _ source: Orbe.DragSession.Source, translation: CGFloat = 0, dropIndex: Int = 0
  ) -> Orbe.DragSession {
    Orbe.DragSession(
      source: source, start: .zero, geometry: geometry, translation: translation,
      dropIndex: dropIndex)
  }

  // MARK: - 描くセグメント列

  /// controller が流し込まない（segments 無し）ホストでは全タブ単独。流し込まれていればそのまま。
  func testStripDefaultsToSingletonsWhenSegmentsNotProvided() {
    XCTAssertEqual(TabStrip(titles: ["a", "b", "c"]).ranges, [0..<1, 1..<2, 2..<3], "無ければ単独")
    XCTAssertEqual(
      TabStrip(titles: ["a", "b", "c"], segments: [0..<2, 2..<3]).ranges, [0..<2, 2..<3],
      "流し込まれた連はそのまま")
  }

  // MARK: - セルの掴み（自セグメントの中だけ）

  /// 動かさなければ自分の位置（no-op）。隣の中心を越えたら挿入前 index 基準で 1 つ先の挿入先。
  func testCellDropIndexUsesPreRemovalIndexing() {
    XCTAssertEqual(StatusRowView.dropIndex(session(.tab(1))), 1, "自分の位置")
    XCTAssertEqual(
      StatusRowView.dropIndex(session(.tab(1), translation: 60)), 2, "隣の中心手前＝直後（実移動なし）")
    XCTAssertEqual(StatusRowView.dropIndex(session(.tab(1), translation: 110)), 3, "隣の中心を越えた＝その後ろ")
    XCTAssertEqual(StatusRowView.dropIndex(session(.tab(1), translation: -60)), 1, "左隣の中心手前")
    XCTAssertEqual(StatusRowView.dropIndex(session(.tab(1), translation: -110)), 0, "左隣の中心を越えた＝先頭")
  }

  /// どれだけ引いても挿入先は自セグメントの端（lowerBound…upperBound）で止まる。
  func testCellDropIndexIsClampedToItsSegment() {
    XCTAssertEqual(
      StatusRowView.dropIndex(session(.tab(1), translation: 1000)), 3, "右端 = upperBound")
    XCTAssertEqual(
      StatusRowView.dropIndex(session(.tab(1), translation: -1000)), 0, "左端 = lowerBound")
    XCTAssertEqual(StatusRowView.dropIndex(session(.tab(4), translation: -1000)), 4, "後ろの連の左端で止まる")
  }

  /// 掴んだセルの表示 offset は、器（自セグメントのセル域）の外へ出ない範囲に収める。
  func testCellOffsetIsClampedInsideItsSegment() {
    XCTAssertEqual(StatusRowView.cellOffset(session(.tab(1), translation: 30)), 30, "器の中は追従")
    XCTAssertEqual(StatusRowView.cellOffset(session(.tab(1), translation: 1000)), 100, "右端で張り付く")
    XCTAssertEqual(StatusRowView.cellOffset(session(.tab(1), translation: -1000)), -100, "左端で張り付く")
  }

  /// セル掴みのキャレットは連内のセル境界（右端は連の右端）に中央合わせ（幅 2 → 左端は line − 1）。
  func testCellCaretSitsOnCellBoundaryWithinSegment() {
    XCTAssertEqual(
      StatusRowView.insertionCaretX(session(.tab(1), dropIndex: 0)), bar - 1, "先頭セルの左端")
    XCTAssertEqual(
      StatusRowView.insertionCaretX(session(.tab(1), dropIndex: 2)), bar + 200 - 1, "セル 2 の左端")
    XCTAssertEqual(
      StatusRowView.insertionCaretX(session(.tab(1), dropIndex: 3)), bar + 300 - 1, "連の右端")
  }

  // MARK: - 掴み状態の遷移

  /// 掴みが凍結している構造は連ごとのタブ同一性。連の分割だけが変わる（tabIds は不変）更新でも変わり、
  /// タイトルだけの更新では変わらない——破棄トリガはこれを観る。
  func testDragStructureFollowsSegmentationNotJustTabIds() {
    let before = TabStrip(titles: ["a", "b", "c"], tabIds: [1, 2, 3], segments: [0..<1, 1..<3])
    let merged = TabStrip(titles: ["a", "b", "c"], tabIds: [1, 2, 3], segments: [0..<2, 2..<3])
    let retitled = TabStrip(titles: ["a", "B", "c"], tabIds: [1, 2, 3], segments: [0..<1, 1..<3])

    XCTAssertEqual(before.tabIds, merged.tabIds, "前提: 集合と順序は同じ")
    XCTAssertNotEqual(before.dragStructure, merged.dragStructure, "連の分割が変われば変わる")
    XCTAssertEqual(before.dragStructure, retitled.dragStructure, "タイトルだけでは変わらない")
  }

  /// 破棄した掴みは、同じ掴みの後続 onChanged で復活せず、onEnded でも commit しない。別の掴み
  /// （startLocation が違う）は起こせる。
  func testDiscardedDragNeitherResumesNorCommits() {
    var state = DragState()
    state.track(source: .tab(1), start: CGPoint(x: 10, y: 5), translation: 8, geometry: geometry)
    XCTAssertNotNil(state.session, "前提: 掴んでいる")

    state.discard()
    XCTAssertNil(state.session, "破棄で掴みは消える")
    state.track(source: .tab(1), start: CGPoint(x: 10, y: 5), translation: 40, geometry: geometry)
    XCTAssertNil(state.session, "同じ掴みの続きでは復活しない")
    XCTAssertNil(state.end(), "破棄後の onEnded は commit しない")

    state.track(source: .tab(2), start: CGPoint(x: 99, y: 5), translation: 0, geometry: geometry)
    XCTAssertEqual(state.session?.source, .tab(2), "別の掴みは起こせる")
    XCTAssertEqual(state.end()?.source, .tab(2), "その掴みは commit される")
    XCTAssertNil(state.session, "commit 後は畳まれる")
  }

  // MARK: - セグメントの掴み（境界だけ）

  /// 挿入先はセグメント境界（タブ index で表す）。隣の連の中心を越えるまでは自分の境界（no-op）。
  func testSegmentDropIndexSnapsToSegmentBoundaries() {
    XCTAssertEqual(StatusRowView.dropIndex(session(.segment(0))), 0, "自分の左境界")
    let ownCenter = (bar + 300) / 2
    let neighborCenter = bar + 300 + gap + 50
    let toNeighborCenter = neighborCenter - ownCenter
    XCTAssertEqual(
      StatusRowView.dropIndex(session(.segment(0), translation: toNeighborCenter - 5)), 3,
      "隣の中心手前＝自連の右境界")
    XCTAssertEqual(
      StatusRowView.dropIndex(session(.segment(0), translation: toNeighborCenter + 5)), 4,
      "隣の中心を越えた＝その後ろ")
    XCTAssertEqual(StatusRowView.dropIndex(session(.segment(0), translation: 1000)), 6, "末尾 = タブ総数")
    XCTAssertEqual(StatusRowView.dropIndex(session(.segment(2), translation: -1000)), 0, "先頭")
  }

  /// セグメント掴みのキャレットはセグメント間の隙間の中央（末尾は行末の外側）。
  func testSegmentCaretSitsInGapCenter() {
    let seg2X = bar + 400 + gap * 2
    XCTAssertEqual(
      StatusRowView.insertionCaretX(session(.segment(0), dropIndex: 4)), seg2X - gap / 2 - 1)
    XCTAssertEqual(
      StatusRowView.insertionCaretX(session(.segment(0), dropIndex: 6)),
      seg2X + bar + 200 + gap / 2 - 1)
    XCTAssertEqual(
      StatusRowView.insertionCaretX(session(.segment(2), dropIndex: 0)), 0, "先頭は 0 で止める")
  }
}
