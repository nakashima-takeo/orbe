import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// スクロールした位置の 1 コマ——本文・行番号・git の印が同じ 1 コマで描かれ、互いにずれない。縦に送れば 3 つが同じ量
/// だけ動き、横に送れば本文だけが動いて行番号と印は留まる。壊れると、スクロール中に印や行番号が本文の行と食い違う、
/// 横に送ると行番号の列まで流れる。
@MainActor
final class ScrolledFrameTests: EngineTestCase {
  private nonisolated static let background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

  /// 印の付く行と付かない行が混ざり、横にも送れる長さの行を持つ本文と、その基準（行 3・4 が変更、行 8 の前が削除、
  /// 行 12〜13 が追加）。
  private static let baseline =
    (0..<40).map { "let value\($0) = \($0)  // " }
    .joined(separator: "\n") + "\n"
  private static let text: String = {
    var lines = baseline.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    lines[2] = "let changed2 = [\"a\", \"b\"]  // " + String(repeating: "x", count: 120)
    lines[3] = "let changed3 = 3.14"
    lines.remove(at: 7)
    lines.insert(contentsOf: ["// added 1", "// added 2"], at: 10)
    return lines.joined(separator: "\n")
  }()

  private func openMarked() throws -> Opened {
    let opened = try open(Self.text, size: CGSize(width: 500, height: 300))
    opened.document.baseline = Self.baseline
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    XCTAssertFalse(opened.surface.drawn.marks.bars.isEmpty, "前提: 印が届いている")
    return opened
  }

  private func shoot(_ opened: Opened) throws -> Shot {
    let id = opened.surface.id
    opened.surface.flush()
    let image = try XCTUnwrap(
      RenderThread.shared.performAndWait {
        Transfer(value: $0.snapshot(id, background: Self.background))
      }.value)
    let config = opened.surface.config
    return Shot(
      bytes: GlyphPixelTests.pixels(image), width: image.width, height: image.height,
      top: Int((config.topInset * 2).rounded()),
      column: Int((config.columnWidth(lineCount: opened.document.text.lineCount) * 2).rounded()))
  }

  /// 縦に送ると、本文・行番号・印が同じ画素の数だけ上へ動く（1 行の高さの倍数でない量でも）。
  func testVerticalScrollMovesTextNumbersAndMarksTogether() throws {
    let opened = try openMarked()
    let before = try shoot(opened)
    let text = opened.document.text
    opened.surface.scroll(toTop: text.lineStart(1), hiddenFraction: 0.5)
    let after = try shoot(opened)
    let shift = 27 * 2
    let region = after.pixels(x: 0..<after.width, y: after.top..<after.height - shift)
    XCTAssertGreaterThan(region.ink(in: after), 1_000, "前提: 字と印が描かれている")
    let worst = region.worstDifference(after, before, dx: 0, dy: shift)
    XCTAssertEqual(worst, 0, "送った量だけ 3 つがそろって動く")
  }

  /// 横に送ると本文だけが動き、行番号の列（行番号と印）は動かない。
  func testHorizontalScrollMovesOnlyTheText() throws {
    let opened = try openMarked()
    let before = try shoot(opened)
    opened.surface.scroll(ScrollInput(timestamp: 0, delta: SIMD2(-3, 0), precise: false))
    XCTAssertEqual(
      opened.surface.viewport.hiddenColumns * opened.surface.config.cell, 30, accuracy: 1e-6)
    let after = try shoot(opened)
    let shift = 30 * 2
    let gutter = after.pixels(x: 0..<after.column, y: after.top..<after.height)
    XCTAssertGreaterThan(gutter.ink(in: after), 200, "前提: 行番号と印が描かれている")
    XCTAssertEqual(gutter.worstDifference(after, before, dx: 0, dy: 0), 0, "行番号の列は動かない")
    let body = after.pixels(x: after.column..<after.width - shift, y: after.top..<after.height)
    XCTAssertGreaterThan(body.ink(in: after), 1_000)
    XCTAssertEqual(body.worstDifference(after, before, dx: shift, dy: 0), 0, "本文は送った量だけ動く")
  }
}

/// 撮った絵（2x、px）。
private struct Shot {
  let bytes: [UInt8]
  let width: Int
  let height: Int
  /// 上端の余白と行番号の列の幅（px）。
  let top: Int
  let column: Int

  func pixels(x: Range<Int>, y: Range<Int>) -> Region { Region(x: x, y: y) }

  func rgb(_ x: Int, _ y: Int) -> [Int] {
    let i = (y * width + x) * 4
    return [Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i])]
  }
}

/// 絵の中の矩形（px）。
private struct Region {
  let x: Range<Int>
  let y: Range<Int>

  /// 地（黒）でない画素の数。
  func ink(in shot: Shot) -> Int {
    var count = 0
    for py in y {
      for px in x where shot.rgb(px, py).contains(where: { $0 != 0 }) { count += 1 }
    }
    return count
  }

  /// `a` の各画素と、`b` の (x + dx, y + dy) の画素の RGB の差の最大。
  func worstDifference(_ a: Shot, _ b: Shot, dx: Int, dy: Int) -> Int {
    var worst = 0
    for py in y {
      for px in x {
        let p = a.rgb(px, py)
        let q = b.rgb(px + dx, py + dy)
        worst = max(worst, zip(p, q).map { abs($0 - $1) }.max()!)
      }
    }
    return worst
  }
}
