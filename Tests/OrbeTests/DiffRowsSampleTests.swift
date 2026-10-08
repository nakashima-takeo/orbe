import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 並列の diff の 2 面の揃え方——変わった区間は削除と追加を上から同じ行（同じ y）に並べ、行の数の差の分だけ短い側の区間の
/// 後に詰め物が入り、続く同じ行も左右で同じ y に来る（見本の `diffLeft` / `diffRight` と VS Code の並列）。壊れると、削除
/// 行と追加行が上下に別々に置かれ、両側に空きができて見比べられない。
@MainActor
final class DiffRowsSampleTests: OrbeTestCase {
  /// 見本（orbe_design の `data.ts` の `diffLines`）と同じ形——同じ 2 行・削除 2 行と追加 8 行の区間・同じ 1 行・追加
  /// 1 行・同じ 1 行。
  private let sample = DiffRowsSample(
    rows: [.same("a"), .same("")] + (0..<2).map { .removed("del \($0)") }
      + (0..<8).map { .added("add \($0)") } + [.same("ctx"), .added("}"), .same("end")])

  private func surface(_ text: String, _ rows: SurfaceRows) throws -> MetalTextSurface {
    let style = DiffRowsSample.style(trailing: 8)
    let surface = MetalTextSurface(style: style, omittedLabel: { "+\($0)" })
    let url = try caseFile("\(UUID().uuidString).txt", text)
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: LanguageRegistry(
        queriesRoot: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()))
    addTeardownBlock { _ = document }
    surface.setPresentation(DiffRowsSample.sidePresentation)
    surface.setRows(rows)
    return surface
  }

  func testChangedBlocksLineUpRowByRow() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let left = try surface(sample.old, sample.side(.old))
    let right = try surface(sample.new, sample.side(.new))
    XCTAssertEqual(
      sample.blocks,
      [
        .same(2), .changed(removed: 2, added: 8), .same(1), .changed(removed: 0, added: 1),
        .same(1),
      ])
    var (old, new) = (0, 0)
    for block in sample.blocks {
      switch block {
      case .same(let count):
        for _ in 0..<count {
          XCTAssertEqual(left.rows.y(ofLine: old), right.rows.y(ofLine: new), "同じ行 \(old)/\(new)")
          old += 1
          new += 1
        }
      case .changed(let removed, let added):
        for k in 0..<min(removed, added) {
          XCTAssertEqual(
            left.rows.y(ofLine: old + k), right.rows.y(ofLine: new + k), "削除と追加が同じ行に並ぶ")
        }
        if removed > 0 { XCTAssertEqual(left.rows.style(ofLine: old), DiffRowsSample.removed) }
        if added > 0 { XCTAssertEqual(right.rows.style(ofLine: new), DiffRowsSample.added) }
        old += removed
        new += added
      }
    }
    let lineHeight = Double(left.config.lineHeight)
    XCTAssertEqual(left.rows.y(ofLine: 4), 10 * lineHeight, "左は削除 2 行の後に詰め物 6 行（見本と同じ）")
    XCTAssertEqual(left.rows.y(ofLine: 5), 12 * lineHeight, "追加 1 行の向かいに詰め物 1 行")
    XCTAssertEqual(left.rows.y(ofLine: 2), right.rows.y(ofLine: 2))
    XCTAssertEqual(
      left.rows.style(ofLine: 2), DiffRowsSample.removed, "向かいの 1 行目どうしが削除と追加")
    XCTAssertEqual(right.rows.style(ofLine: 2), DiffRowsSample.added)
  }
}
