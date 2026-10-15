import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の計測（記録）。`ORBE_EDITOR_PERF=1` のときだけ走る（`scripts/perf-editor.sh` が回す）。1MB の Swift の大きな書き換え
/// ——編集の数が diff の上限の近く・上限越え・全行——で、裏の行差分の時間（上限の値の根拠）と、並びを作って面に置く main の
/// 仕事（diff を開く・取り直すとき）を `PERF` で始まる行に出す。
@MainActor
final class EditorDiffPerfTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
  }

  func testLargeRewrite() throws {
    let source = EditorTypingPerfTests.swiftSource(bytes: 1_000_000)
    let lines = source.components(separatedBy: "\n")
    let changing = { (every: Int) in
      lines.enumerated().map { $0 % every == 3 ? $1 + " // changed" : $1 }.joined(separator: "\n")
    }
    let cases = [
      ("1MB edits near the bound", source, changing(9)),
      ("1MB edits over the bound", source, changing(4)),
      ("1MB whole rewrite", source, lines.map { $0 + " // rewritten" }.joined(separator: "\n")),
    ]
    for (label, old, new) in cases {
      let (oldRope, newRope) = (TextRope(old), TextRope(new))
      var started = CACurrentMediaTime()
      let hunks = LineDiff.hunks(old: oldRope, new: newRope, limit: EditorDiff.hunkLimit)
      let background = CACurrentMediaTime() - started
      let gutter = LineDiff.hunks(old: oldRope, new: newRope, limit: LineDiff.gutter)

      let url = try caseFile("\(UUID().uuidString).swift", new)
      let surface = try XCTUnwrap(
        makeMetalTextSurface(style: EditorStyle.make(), omittedLabel: { "\($0)" })
          as? MetalTextSurface)
      let document = EditorDocument(
        url: url, contents: try EditorDocument.read(url), surface: surface,
        registry: LanguageRegistry(queriesRoot: nil))
      let source = RevisionDocument(
        text: old, name: url, registry: LanguageRegistry(queriesRoot: nil))
      surface.viewStateDidChange(size: CGSize(width: 900, height: 700), scale: 2, visible: false)
      surface.setPresentation(DiffStyle.inline)
      started = CACurrentMediaTime()
      var rows = DiffRows.inline(hunks, old: DiffRows.Side(oldRope), new: DiffRows.Side(newRope))
      rows.source = source
      surface.setRows(rows)
      surface.flush()
      let place = CACurrentMediaTime() - started
      print(
        "PERF diff", label, "lines", oldRope.lineCount, "/", newRope.lineCount, "hunks",
        hunks.count, "(gutter limit", gutter.count, ") background line diff", ms(background),
        "main rows place", ms(place), "insertions", surface.rows.count)
      withExtendedLifetime((document, source)) {}
    }
  }

  private func ms(_ seconds: Double) -> String { String(format: "%.1fms", seconds * 1000) }
}
