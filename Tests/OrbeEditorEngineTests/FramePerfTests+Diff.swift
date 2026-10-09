import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// diff の面の計測（`FramePerfTests` と同じ場で、`ORBE_EDITOR_PERF=1` のときだけ走る）。インラインは 1MB の文書に、8 行
/// ごとに別の 1MB の版（構文の色つき）の 3 行を指す削除の差し込みを置き（約 1.6 万行）、行の型の地と記号を付ける。並列は
/// 1MB の 2 面に詰め物の差し込みを置き、スクロールを共にして片側だけに指を流す。関門は本文だけのときと同じ（1 コマの CPU の
/// p99 2ms 未満・描画スレッド自身が落とすコマ 0）。壊れると、削除行の多い diff や並列の diff でスクロールのコマが落ちる。
extension FramePerfTests {
  func testDiffInline() throws {
    let old = try open(
      Self.swiftSource(bytes: 1_000_000).replacingOccurrences(of: "Item", with: "Old"))
    let source = DocumentRowSource(old.document)
    _ = try measure(label: "1MB diff inline", text: Self.swiftSource(bytes: 1_000_000)) { opened in
      let lineCount = opened.document.text.lineCount
      opened.surface.setPresentation(Self.diffPresentation(columns: 2))
      opened.surface.setRows(Self.inlineRows(lineCount: lineCount, source: source))
      opened.surface.isEditable = false
    }
  }

  func testDiffSideBySide() throws {
    let text = Self.swiftSource(bytes: 1_000_000)
    let left = try attach(text.replacingOccurrences(of: "Item", with: "Old"))
    let right = try attach(text)
    for (index, opened) in [left, right].enumerated() {
      opened.surface.setPresentation(Self.diffPresentation(columns: 1))
      opened.surface.setRows(
        Self.paddedRows(lineCount: opened.document.text.lineCount, odd: index == 1))
      opened.surface.isEditable = false
    }
    left.surface.shareScroll(with: right.surface)
    waitUntilIdle(left.surface)
    waitUntilIdle(right.surface)
    print("PERF-FRAMES 1MB diff side lines", right.document.text.lineCount)
    for loaded in [false, true] {
      let name = loaded ? "main-load" : "no-load"
      if loaded { startLoad() }
      for driven in [left, right] {
        reset(left.surface)
        reset(right.surface)
        runDrag([driven.surface], seconds: 3, speed: 2400)
        runFlick(driven.surface, peak: 6000)
        waitUntilIdle(left.surface)
        waitUntilIdle(right.surface)
        let side = driven.surface === left.surface ? "driven-left" : "driven-right"
        report("1MB diff side left", "\(name) \(side)", totals(left.surface))
        report("1MB diff side right", "\(name) \(side)", totals(right.surface))
        XCTAssertEqual(left.surface.scrollPosition, right.surface.scrollPosition, "2 面は同じ位置")
      }
      load?.invalidate()
      load = nil
    }
  }

  /// 行の型 0（追加の地と記号）・1（削除の地と記号）・2（詰め物の地）の構成。
  static func diffPresentation(columns: Int) -> SurfacePresentation {
    SurfacePresentation(
      showsMinimap: false, numberColumns: columns, numberWidth: 44, numberTrailing: 6,
      signWidth: columns == 2 ? 18 : 0, showsMarks: false,
      lineStyles: [
        LineStyle(
          background: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 0.12), sign: "+",
          signColor: .systemBlue),
        LineStyle(
          background: NSColor(srgbRed: 0.9, green: 0.5, blue: 0.2, alpha: 0.12), sign: "−",
          signColor: .systemOrange),
        LineStyle(background: NSColor(white: 1, alpha: 0.02)),
      ])
  }

  /// 8 行ごとに、6 行の文脈の区間と、出どころの 3 行を指す削除の差し込みと、2 行の追加の区間。
  static func inlineRows(lineCount: Int, source: DocumentRowSource) -> SurfaceRows {
    var insertions: [RowInsertion] = []
    var spans: [LineSpan] = []
    var old = 0
    let last = source.rowSourceContent.text.lineCount - 1
    for start in stride(from: 0, to: lineCount - 8, by: 8) {
      spans.append(LineSpan(line: start, otherNumber: old + 1))
      old += 6
      let removed = (0..<3).map { InsertedLine(line: min(old + $0, last), style: 1) }
      insertions.append(RowInsertion(line: start + 6, content: .lines(removed)))
      old += 3
      spans.append(LineSpan(line: start + 6, style: 0))
    }
    return SurfaceRows(insertions: insertions, spans: spans, source: source)
  }

  /// 12 行ごとに 3 行の詰め物（`odd` なら 6 行ずらす）。
  static func paddedRows(lineCount: Int, odd: Bool) -> SurfaceRows {
    let pads = (0..<3).map { _ in InsertedLine(style: 2) }
    return SurfaceRows(
      insertions: stride(from: odd ? 6 : 12, to: lineCount, by: 12).map {
        RowInsertion(line: $0, content: .lines(pads))
      })
  }
}

/// 文書の写しを出どころにする（構文の色つきの削除行を描かせる）。
@MainActor
final class DocumentRowSource: SurfaceRowSource {
  let document: EditorDocument

  init(_ document: EditorDocument) {
    self.document = document
  }

  var rowSourceContent: SurfaceContent {
    SurfaceContent(text: document.text, roles: document.roles, version: document.version)
  }
}
