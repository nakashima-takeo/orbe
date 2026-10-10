import CoreGraphics
import XCTest

@testable import Orbe

/// 面の配置の正規形（`FaceLayout.normalized`）と幾何の純粋関数（`FaceGeometry`）——境の位置と形から各面・両面の間・
/// 取っ手の矩形と位置ドットを解き、⌘E・取っ手を押す／離したときの次の配置を決める規則。
///
/// 壊れると何が起きるか。正規形が破れると「記憶した焦点」が隠れた面を指し、キーと first responder が
/// 見えない面へ届く。resolve がずれると端末の pty 幅が見えている面と食い違い、位置ドットと引き手が
/// 実態と別の面を示す。toggle / handleClick が違う面を選ぶと ⌘E と引き手を押す操作が「戻れない」操作になり、
/// release の境がずれると取っ手を離した瞬間に意図しない面が閉じる。
final class FaceGeometryTests: OrbeTestCase {
  /// 取っ手の幅 12 を除いた位置の最大（MAX）が 1000 になる器。
  private let size = CGSize(width: 1012, height: 400)
  private var width: CGFloat { size.width }

  private func resolved(_ ratio: Double, _ focus: Face) -> FaceGeometry.Resolved {
    FaceGeometry.resolve(FaceLayout(editorRatio: ratio, focus: focus), size: size)
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

  /// 分割中は境に幅 12 の継ぎ目が全高で立ち、エディターはその左、端末はその右に並ぶ。
  func testResolveSplitPlacesTheSeamBetweenTheFaces() {
    let g = resolved(0.25, .terminal)

    XCTAssertEqual(g.shape, .init(hx: 250, sL: 1, sR: 1))
    XCTAssertEqual(g.frames.editor, CGRect(x: 0, y: 0, width: 250, height: 400))
    XCTAssertEqual(g.frames.gap, CGRect(x: 250, y: 0, width: 12, height: 400))
    XCTAssertEqual(g.frames.terminal, CGRect(x: 262, y: 0, width: 750, height: 400))
    XCTAssertEqual(g.frames.handle, CGRect(x: 250, y: 0, width: 12, height: 400))
    XCTAssertEqual(g.frames.t, 1)
    XCTAssertTrue(g.isSplit)
    XCTAssertEqual(g.projection.dots, .init(editor: .on, terminal: .focus), "焦点の面だけ focus、他は on")
  }

  /// 端末だけの配置: 端末が器いっぱいで、左縁の縦中央にエディターの引き手が重なる。ドットはエディター off。
  func testResolveTerminalOnlyShowsTheEditorNotch() {
    let g = resolved(0, .terminal)

    XCTAssertEqual(g.editorWidth, 0)
    XCTAssertEqual(g.frames.terminal, CGRect(origin: .zero, size: size), "全面は器いっぱい")
    XCTAssertEqual(g.frames.handle, CGRect(x: 0, y: 176, width: 12, height: 48))
    XCTAssertEqual(g.frames.t, 0)
    XCTAssertTrue(g.frames.edgeOnLeft)
    XCTAssertFalse(g.isSplit)
    XCTAssertEqual(g.projection.dots, .init(editor: .off, terminal: .focus))
  }

  /// エディター全面: エディターが器いっぱいで、右縁の縦中央に端末の引き手が重なる。ドットは端末 off。
  func testResolveEditorOnlyShowsTheTerminalNotch() {
    let g = resolved(1, .editor)

    XCTAssertEqual(g.frames.editor, CGRect(origin: .zero, size: size), "全面は器いっぱい")
    XCTAssertEqual(g.terminalWidth, 0)
    XCTAssertEqual(g.frames.handle, CGRect(x: 1000, y: 176, width: 12, height: 48))
    XCTAssertFalse(g.frames.edgeOnLeft)
    XCTAssertFalse(g.isSplit)
    XCTAssertEqual(g.projection.dots, .init(editor: .focus, terminal: .off))
  }

  /// 位置は点に丸め、端末が残りを取る（両面と継ぎ目の合計が器の幅から欠けない）。
  func testResolveRoundsThePositionAndGivesTheRemainderToTheTerminal() {
    let g = resolved(1.0 / 3.0, .terminal)

    XCTAssertEqual(g.editorWidth, 333)
    XCTAssertEqual(g.terminalWidth, 667)
    XCTAssertEqual(g.editorWidth + 12 + g.terminalWidth, width)
  }

  /// 縁の近くの形の途中では、両面の間は形に応じて狭く、取っ手は引き手と全高の間の高さ。
  func testFramesBetweenTheNotchAndTheSeam() {
    let f = FaceGeometry.frames(.init(hx: 28, sL: 0.5, sR: 1), size: size)

    XCTAssertEqual(f.editor.maxX, 28)
    XCTAssertEqual(f.gap, CGRect(x: 28, y: 0, width: 6, height: 400))
    XCTAssertEqual(f.terminal.minX, 34)
    XCTAssertEqual(f.t, 0.5)
    XCTAssertEqual(f.handle.height, 224)
  }

  /// 負の器の大きさは 0 として解く（面の幅が負にならない）。
  func testResolveNegativeWidthHasNoContent() {
    let g = FaceGeometry.resolve(
      FaceLayout(editorRatio: 0.5, focus: .editor), size: CGSize(width: -10, height: 400))

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

  // MARK: - 取っ手を離す

  /// 勢いで 0.12 秒先へ滑った位置が端から 24 以内なら閉じ（その端を返す）、それ以外はその場に留まる。
  func testReleaseClosesOnlyWhenTheProjectionReachesTheEdge() {
    XCTAssertEqual(FaceGeometry.release(hx: 20, velocity: 0, width: width), 0, "端の近くで離すと閉じる")
    XCTAssertNil(FaceGeometry.release(hx: 30, velocity: 0, width: width), "止めて離せば留まる")
    XCTAssertEqual(
      FaceGeometry.release(hx: 100, velocity: -1000, width: width), 0, "左へ投げると端末へ閉じる")
    XCTAssertEqual(
      FaceGeometry.release(hx: 900, velocity: 1000, width: width), 1000, "右へ投げるとエディターへ閉じる")
    XCTAssertNil(FaceGeometry.release(hx: 500, velocity: 300, width: width), "中ほどは勢いがあっても留まる")
  }

  /// 割合は位置 ÷ MAX。取っ手より狭い器では nil。
  func testRatioIsThePositionOverTheMaximum() {
    XCTAssertEqual(FaceGeometry.ratio(hx: 250, width: width), 0.25)
    XCTAssertNil(FaceGeometry.ratio(hx: 0, width: 12))
  }
}
