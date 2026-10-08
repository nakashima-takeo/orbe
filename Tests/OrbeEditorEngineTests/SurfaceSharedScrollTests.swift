import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// スクロールを共にする 2 面（並列の diff）——どちらの面の指も両面を同じ位置へ動かし、同じ刻みに同じ位置を描き、範囲は
/// 大きい方で、見せる操作にも両面が従い、同じ周に置いた並びのずらしは 1 回だけ。壊れると、並列の左右が食い違ってずれた
/// 行を見比べる、短い側の端で長い側が止まる、diff を取り直すたびに片側だけ跳ねる。
@MainActor
final class SurfaceSharedScrollTests: EngineTestCase {
  private let size = CGSize(width: 400, height: 300)

  /// 行数の違う 2 面（左が長い）を結んだもの。
  private func pair(left: Int = 200, right: Int = 120) throws -> (Opened, Opened) {
    let a = try open(rows(left), size: size)
    let b = try open(rows(right, width: 60), size: size)
    for opened in [a, b] {
      opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    }
    a.surface.shareScroll(with: b.surface)
    return (a, b)
  }

  private func finger(
    _ surface: MetalTextSurface, _ t: Double, _ dy: Double, _ phase: ScrollInput.Phase
  ) {
    surface.scroll(ScrollInput(timestamp: t, delta: SIMD2(0, dy), precise: true, phase: phase))
  }

  /// どちらの面で指を動かしても、両面の位置は同じ。
  func testAFingerOnEitherSurfaceMovesBoth() throws {
    let (a, b) = try pair()
    finger(b.surface, 1, 0, .began)
    finger(b.surface, 1.01, -300, .changed)
    XCTAssertEqual(b.surface.scrollPosition.y, 300)
    XCTAssertEqual(a.surface.scrollPosition, b.surface.scrollPosition)
    finger(a.surface, 1.02, 100, .changed)
    XCTAssertEqual(a.surface.scrollPosition.y, 200)
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
    XCTAssertEqual(
      b.surface.viewport.firstVisible, b.document.text.lineStart(Int(200 / 18)),
      "動かしていない面の見えている範囲も知らせ直す")
  }

  /// 縦の範囲は長い方の面の端まで——短い面も長い面の最後の行まで送れる。横の範囲は長い行の面の端まで。
  func testTheRangeIsTheLargerOfTheTwo() throws {
    let (a, b) = try pair()
    _ = a.surface.snapshot()
    _ = b.surface.snapshot()
    let longest = a.surface.rows.lastTop(lineCount: a.document.text.lineCount)
    XCTAssertEqual(b.surface.scrollState().limits.maximum.y, longest)
    b.surface.scrollToDocumentEdge(end: true)
    b.surface.scroll(toFirstLine: 1e9)
    b.surface.flush()
    XCTAssertEqual(a.surface.scrollPosition.y, longest, "短い面から長い面の最後まで送れる")
    let wide = b.surface.scrollState().limits.maximum.x
    XCTAssertGreaterThan(wide, 0, "前提: 右の面の行は見えている幅より長い")
    XCTAssertEqual(a.surface.scrollState().limits.maximum.x, wide, "短い行の面も右へ送れる")
  }

  /// 刻みの位置は最初に読んだ面が封じる——同じ刻みの間に届いた指の出来事は、もう一方の面のその刻みには出ず、次の刻みに
  /// 出る。
  func testBothSurfacesDrawTheSamePositionOnATick() throws {
    let (a, b) = try pair()
    let period = 1.0 / 60
    let tick = 100 * period
    let revisions = (a.surface.drawn.revision, b.surface.drawn.revision)
    let first = a.surface.scroll.frame(at: tick, period: period, material: revisions.0)
    finger(a.surface, 1, 0, .began)
    finger(a.surface, 1.01, -120, .changed)
    let second = b.surface.scroll.frame(at: tick, period: period, material: revisions.1)
    XCTAssertEqual(second.position, first.position, "同じ刻みは同じ位置")
    let next = b.surface.scroll.frame(at: tick + period, period: period, material: revisions.1)
    XCTAssertEqual(next.position.y, 120, "次の刻みで出る")
    XCTAssertEqual(
      a.surface.scroll.frame(at: tick + period, period: period, material: revisions.0).position,
      next.position)
  }

  /// 区間を見せると両面がその位置へ動く。
  func testRevealMovesBoth() throws {
    let (a, b) = try pair()
    let text = a.document.text
    a.surface.reveal(NSRange(location: text.lineStart(150), length: 0), policy: .center)
    a.surface.flush()
    XCTAssertGreaterThan(a.surface.scrollPosition.y, 0)
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
  }

  /// 同じ周に両面の差し込みを置き直しても、見えている先頭の行を保つずらしは 1 回だけ（両面が揃ったまま跳ねない）。
  func testRowsReplacedInTheSameCycleShiftOnce() throws {
    let (a, b) = try pair()
    a.surface.scroll(toFirstLine: 50)
    a.surface.flush()
    let before = a.surface.scrollPosition.y
    let lines = (0..<3).map { InsertedLine("pad \($0)") }
    for surface in [a.surface, b.surface] {
      surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .lines(lines))]))
    }
    a.surface.flush()
    XCTAssertEqual(a.surface.scrollPosition.y, before + 3 * 18)
    XCTAssertEqual(b.surface.scrollPosition, a.surface.scrollPosition)
    XCTAssertEqual(a.surface.viewport.firstVisible, a.document.text.lineStart(50))
  }

  /// 面が閉じれば外れ、残った面の範囲は自分の本文だけで決まる。
  func testClosingOneSurfaceDetachesIt() throws {
    let a = try open(rows(30), size: size)
    a.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    do {
      let b = try open(rows(300), size: size)
      b.surface.setPresentation(SurfacePresentation(showsMinimap: false))
      a.surface.shareScroll(with: b.surface)
      a.surface.flush()
      XCTAssertGreaterThan(
        a.surface.scrollState().limits.maximum.y, a.surface.rows.lastTop(lineCount: 31),
        "前提: 長い面の範囲を共にしている")
    }
    pump(until: { a.surface.partner == nil }, "相手が閉じれば外れる")
    XCTAssertEqual(
      a.surface.scrollState().limits.maximum.y,
      max(0, a.surface.rows.lastTop(lineCount: a.document.text.lineCount)))
  }
}
