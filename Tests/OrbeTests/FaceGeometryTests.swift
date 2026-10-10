import CoreGraphics
import XCTest

@testable import Orbe

/// 面の配置の正規形（`FaceLayout.normalized`）と幾何の純粋関数（`FaceGeometry`）——器の幅から各面の
/// px と取っ手（引き手・継ぎ目）の見え方・位置ドットを解き、⌘E・取っ手を押す／引く／離したときの次の配置を決める規則。
///
/// 壊れると何が起きるか。正規形が破れると「記憶した焦点」が隠れた面を指し、キーと first responder が
/// 見えない面へ届く。resolve がずれると端末の pty 幅が見えている面と食い違い、位置ドットと引き手が
/// 実態と別の面を示す。toggle / handleClick が違う面を選ぶと ⌘E と引き手を押す操作が「戻れない」操作になり、
/// drag / release の境がずれると取っ手を離した瞬間に意図しない面が閉じる。
final class FaceGeometryTests: OrbeTestCase {
  private let width: CGFloat = 1000

  private func resolved(_ ratio: Double, _ focus: Face) -> FaceGeometry.Resolved {
    FaceGeometry.resolve(FaceLayout(editorRatio: ratio, focus: focus), width: width)
  }

  // MARK: - 正規形

  /// 割合は 0…1 に収まり、全面の側（0 なら端末・1 ならエディター）へ焦点が寄る。
  func testNormalizedPullsFocusToTheFullFace() {
    XCTAssertEqual(
      FaceLayout(editorRatio: 0, focus: .editor).normalized, .terminalOnly, "エディター幅 0 の焦点は端末")
    XCTAssertEqual(
      FaceLayout(editorRatio: 1, focus: .terminal).normalized,
      FaceLayout(editorRatio: 1, focus: .editor), "端末幅 0 の焦点はエディター")
    XCTAssertEqual(
      FaceLayout(editorRatio: 1.5, focus: .terminal).normalized,
      FaceLayout(editorRatio: 1, focus: .editor), "1 を超える割合はエディター全面")
    XCTAssertEqual(
      FaceLayout(editorRatio: -0.5, focus: .editor).normalized, .terminalOnly, "負の割合は端末だけ")
    XCTAssertEqual(
      FaceLayout(editorRatio: .nan, focus: .editor).normalized, .terminalOnly, "数でない割合は既定")
  }

  /// 分割中（0 と 1 の間）は焦点がどちらでもよく、そのまま残る。
  func testNormalizedKeepsFocusWhileSplit() {
    let split = FaceLayout(editorRatio: 0.4, focus: .editor)
    XCTAssertEqual(split.normalized, split)
    XCTAssertEqual(
      FaceLayout(editorRatio: 0.4, focus: .terminal).normalized,
      FaceLayout(editorRatio: 0.4, focus: .terminal))
  }

  // MARK: - resolve

  /// 器の幅をすべて割合で分け、両面が見えていれば継ぎ目と分割中の投影になる。
  func testResolveSplitsTheWholeWidth() {
    let g = resolved(0.25, .terminal)

    XCTAssertEqual(g.width, width)
    XCTAssertEqual(g.editorWidth, 250)
    XCTAssertEqual(g.terminalWidth, 750)
    XCTAssertTrue(g.isSplit)
    XCTAssertEqual(g.projection.handleLook, .seam)
    XCTAssertEqual(g.projection.dots, .init(editor: .on, terminal: .focus), "焦点の面だけ focus、他は on")
  }

  /// 端末だけの配置: エディターは幅 0 で隠れ、取っ手はエディターの引き手、ドットはエディター off。
  func testResolveTerminalOnlyShowsTheEditorNotch() {
    let g = resolved(0, .terminal)

    XCTAssertEqual(g.editorWidth, 0)
    XCTAssertEqual(g.terminalWidth, width)
    XCTAssertFalse(g.isSplit)
    XCTAssertEqual(g.projection.handleLook, .notch(.editor))
    XCTAssertEqual(g.projection.dots, .init(editor: .off, terminal: .focus))
  }

  /// エディター全面: 端末は幅 0 で隠れ、取っ手は端末の引き手、ドットは端末 off。
  func testResolveEditorOnlyShowsTheTerminalNotch() {
    let g = resolved(1, .editor)

    XCTAssertEqual(g.editorWidth, width)
    XCTAssertEqual(g.terminalWidth, 0)
    XCTAssertFalse(g.isSplit)
    XCTAssertEqual(g.projection.handleLook, .notch(.terminal))
    XCTAssertEqual(g.projection.dots, .init(editor: .focus, terminal: .off))
  }

  /// 面の幅は整数 px に丸め、端末が残りを取る（合計が器の幅から欠けない）。
  func testResolveRoundsTheEditorWidthAndGivesTheRemainderToTheTerminal() {
    let g = resolved(1.0 / 3.0, .terminal)

    XCTAssertEqual(g.editorWidth, 333)
    XCTAssertEqual(g.terminalWidth, 667)
    XCTAssertEqual(g.editorWidth + g.terminalWidth, width)
  }

  /// 負の器の幅は 0 として解く（面の幅が負にならない）。
  func testResolveNegativeWidthHasNoContent() {
    let g = FaceGeometry.resolve(FaceLayout(editorRatio: 0.5, focus: .editor), width: -10)

    XCTAssertEqual(g.width, 0)
    XCTAssertEqual(g.editorWidth, 0)
    XCTAssertEqual(g.terminalWidth, 0)
  }

  // MARK: - ⌘E

  /// 分割していなければ端末 ⇄ エディター全面を往復する。
  func testToggleSwapsTheFullFace() {
    XCTAssertEqual(
      FaceGeometry.toggle(resolved(0, .terminal)),
      FaceLayout(editorRatio: 1, focus: .editor), "端末だけ → エディター全面")
    XCTAssertEqual(
      FaceGeometry.toggle(resolved(1, .editor)),
      .terminalOnly, "エディター全面 → 端末だけ")
  }

  /// 分割中は幅を変えず焦点だけを往復する。
  func testToggleWhileSplitOnlyMovesFocus() {
    let terminalFocused = FaceLayout(editorRatio: 0.5, focus: .terminal)
    let editorFocused = FaceLayout(editorRatio: 0.5, focus: .editor)

    XCTAssertEqual(FaceGeometry.toggle(resolved(0.5, .terminal)), editorFocused)
    XCTAssertEqual(FaceGeometry.toggle(resolved(0.5, .editor)), terminalFocused)
  }

  // MARK: - 引き手・グリップを押す

  /// 隣が隠れていれば全開、自分が隠れていれば戻る。
  func testHandleClickOpensTheHiddenFace() {
    XCTAssertEqual(
      FaceGeometry.handleClick(resolved(0, .terminal)),
      FaceLayout(editorRatio: 1, focus: .editor), "端末だけ → エディター全面")
    XCTAssertEqual(
      FaceGeometry.handleClick(resolved(1, .editor)),
      .terminalOnly, "エディター全面 → 端末だけ")
  }

  /// 分割中は焦点の面が全面になる。
  func testHandleClickWhileSplitExpandsTheFocusedFace() {
    XCTAssertEqual(
      FaceGeometry.handleClick(resolved(0.5, .editor)),
      FaceLayout(editorRatio: 1, focus: .editor))
    XCTAssertEqual(
      FaceGeometry.handleClick(resolved(0.5, .terminal)),
      .terminalOnly)
  }

  // MARK: - 取っ手を引く

  /// 境の求める位置がそのままエディター幅になり（隠れている面からも引き出せる）、焦点は掴んだときのまま。
  func testDragFollowsThePointerAndKeepsTheFocus() {
    XCTAssertEqual(
      FaceGeometry.drag(from: resolved(0.5, .terminal), x: 300),
      FaceLayout(editorRatio: 0.3, focus: .terminal))
    XCTAssertEqual(
      FaceGeometry.drag(from: resolved(0.5, .editor), x: 300),
      FaceLayout(editorRatio: 0.3, focus: .editor), "エディター焦点も動かない")
    XCTAssertEqual(
      FaceGeometry.drag(from: resolved(0, .terminal), x: 400),
      FaceLayout(editorRatio: 0.4, focus: .terminal), "隠れている面からも引き出せる")
  }

  /// 器の外へ引いても器の幅の範囲に収まり、端に着いた面へ焦点が移る（正規形）。
  func testDragClampsToTheWidthAndMovesFocusToTheRemainingFace() {
    let editorFocused = FaceLayout(editorRatio: 0.5, focus: .editor)
    let terminalFocused = FaceLayout(editorRatio: 0.5, focus: .terminal)

    XCTAssertEqual(
      FaceGeometry.drag(from: resolved(0.5, .editor), x: -50), .terminalOnly,
      "左端を越えたらエディターが閉じ焦点は端末へ")
    XCTAssertEqual(
      FaceGeometry.drag(from: resolved(0.5, .terminal), x: 2000),
      FaceLayout(editorRatio: 1, focus: .editor), "右端を越えたら端末が閉じ焦点はエディターへ")
  }

  /// 幅 0 の器では配置を変えない（0 で割らない）。
  func testDragWithNoWidthLeavesTheLayout() {
    let split = FaceLayout(editorRatio: 0.5, focus: .terminal)
    let empty = FaceGeometry.resolve(split, width: 0)

    XCTAssertEqual(FaceGeometry.drag(from: empty, x: 100), split)
  }

  // MARK: - 取っ手を離す

  /// 閉じる境（40）より狭い面は閉じ、境ちょうどからは幅をそのまま確定する。
  func testReleaseClosesAFaceNarrowerThanTheCloseEdge() {
    XCTAssertEqual(
      FaceGeometry.release(FaceLayout(editorRatio: 0.039, focus: .terminal), width: 1000),
      .terminalOnly, "エディター 39 は閉じる")
    XCTAssertEqual(
      FaceGeometry.release(FaceLayout(editorRatio: 0.961, focus: .terminal), width: 1000),
      FaceLayout(editorRatio: 1, focus: .editor), "端末 39 は閉じる")

    let editorAtEdge = FaceLayout(editorRatio: 0.04, focus: .terminal)
    XCTAssertEqual(
      FaceGeometry.release(editorAtEdge, width: 1000), editorAtEdge, "エディター 40 は残る")
    let terminalAtEdge = FaceLayout(editorRatio: 0.96, focus: .terminal)
    XCTAssertEqual(
      FaceGeometry.release(terminalAtEdge, width: 1000), terminalAtEdge, "端末 40 は残る")
  }
}
