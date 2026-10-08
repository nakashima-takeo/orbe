import AppKit
import OrbeEditorCore

@testable import Orbe
@testable import OrbeEditorEngine

/// 2 版の行を突き合わせた並び（文脈・削除・追加）から、diff の装備（行の型・番号・詰め物）を組む。diff の flow
/// （`editor_diff_rows`）と、画面に出す試しの場の並列の型（`EditorRowsTrialTests`）が載せる。見え方は見本 D 節の寸法と
/// 色で作ったテストだけの値で、製品の値は diff の画面を作る単位（d1）が持つ。
@MainActor
struct DiffRowsSample {
  /// 突き合わせた行 1 つ。
  enum Row {
    case same(String)
    case removed(String)
    case added(String)
  }

  /// 片側（並列）。
  enum Side { case old, new }

  let rows: [Row]

  /// 旧版と新版の本文（どちらも改行で終わる）。
  var old: String { text { if case .added = $0 { nil } else { $0.line } } }
  var new: String { text { if case .removed = $0 { nil } else { $0.line } } }

  private func text(_ pick: (Row) -> String?) -> String {
    rows.compactMap(pick).map { $0 + "\n" }.joined()
  }

  /// インライン——新版の本文に、削除の行を文書に無い行（旧番号つき）で差し込み、追加の区間と文脈の区間（旧番号の始まり
  /// つき）を置く。
  var inline: SurfaceRows {
    var insertions: [RowInsertion] = []
    var spans: [LineSpan] = []
    var removed: [InsertedLine] = []
    var (oldNext, newNext) = (1, 0)
    var last: Int?
    func open(_ style: Int, other: Int?) {
      guard last != style else { return }
      spans.append(LineSpan(line: newNext, style: style, otherNumber: other))
      last = style
    }
    func flush() {
      guard !removed.isEmpty else { return }
      insertions.append(RowInsertion(line: newNext, content: .lines(removed)))
      removed = []
      last = nil
    }
    for row in rows {
      switch row {
      case .removed(let line):
        removed.append(InsertedLine(line, style: Self.removed, number: oldNext))
        oldNext += 1
      case .added:
        flush()
        open(Self.added, other: nil)
        newNext += 1
      case .same:
        flush()
        open(Self.context, other: oldNext)
        oldNext += 1
        newNext += 1
      }
    }
    flush()
    return SurfaceRows(insertions: insertions, spans: spans)
  }

  /// 並列の片側——自分の側の変わった行に型を付け、相手の側だけにある行の数だけ詰め物の行を差し込む。
  func side(_ side: Side) -> SurfaceRows {
    var insertions: [RowInsertion] = []
    var spans: [LineSpan] = []
    var pads = 0
    var next = 0
    var last: Int?
    func flush() {
      guard pads > 0 else { return }
      let lines = (0..<pads).map { _ in InsertedLine("", style: Self.pad) }
      insertions.append(RowInsertion(line: next, content: .lines(lines)))
      pads = 0
    }
    func own(_ style: Int) {
      flush()
      if last != style { spans.append(LineSpan(line: next, style: style)) }
      last = style
      next += 1
    }
    for row in rows {
      switch (row, side) {
      case (.removed, .old): own(Self.removed)
      case (.added, .new): own(Self.added)
      case (.removed, .new), (.added, .old): pads += 1
      case (.same, _): own(Self.context)
      }
    }
    flush()
    return SurfaceRows(insertions: insertions, spans: spans)
  }

  /// 旧版 `old` と新版 `new` を `LineDiff` で突き合わせた並び。
  static func diff(old: String, new: String) -> DiffRowsSample {
    let oldLines = old.components(separatedBy: "\n").dropLast().map { $0 }
    let newLines = new.components(separatedBy: "\n").dropLast().map { $0 }
    var rows: [Row] = []
    var (oldNext, newNext) = (0, 0)
    for hunk in LineDiff.hunks(base: old, current: TextRope(new)) {
      let oldFirst = hunk.oldCount > 0 ? hunk.oldStart - 1 : hunk.oldStart
      while oldNext < oldFirst {
        rows.append(.same(newLines[newNext]))
        oldNext += 1
        newNext += 1
      }
      rows += oldLines[oldFirst..<(oldFirst + hunk.oldCount)].map(Row.removed)
      let newFirst = hunk.newCount > 0 ? hunk.newStart - 1 : hunk.newStart
      rows += newLines[newFirst..<(newFirst + hunk.newCount)].map(Row.added)
      oldNext = oldFirst + hunk.oldCount
      newNext = newFirst + hunk.newCount
    }
    rows += newLines[newNext...].map(Row.same)
    return DiffRowsSample(rows: rows)
  }

  // MARK: - 見え方

  static let added = 0
  static let removed = 1
  static let context = 2
  static let pad = 3

  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
  }

  private static func hex(_ value: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
  }

  /// 並列の 2 面の区切り（hairline(0.07)）。
  static let hairline = dynamic(light: hex(0x6E5AAA, 0.098), dark: hex(0xC7B9EB, 0.07))

  /// 行の型——追加・削除（地は diffAdd / diffDel の 0.12、字は diffText、記号は + / −）・文脈（字は muted）・詰め物（地は
  /// fill(0.02)）。
  static var styles: [LineStyle] {
    [
      LineStyle(
        background: Theme.Color.diffAdded.withAlphaComponent(0.12),
        text: dynamic(light: hex(0x237A42), dark: hex(0xB5D8BB)), sign: "+",
        signColor: Theme.Color.diffAdded),
      LineStyle(
        background: Theme.Color.diffRemoved.withAlphaComponent(0.12),
        text: dynamic(light: hex(0xB03A3A), dark: hex(0xD3A5A5)), sign: "−",
        signColor: Theme.Color.diffRemoved),
      LineStyle(text: Theme.Color.textMuted),
      LineStyle(background: dynamic(light: hex(0x3A3151, 0.012), dark: hex(0xFFFFFF, 0.02))),
    ]
  }

  /// インラインの構成（番号 2 列・記号の列 18・印の列なし）と、並列の構成（番号 1 列）。
  static var inlinePresentation: SurfacePresentation {
    SurfacePresentation(
      showsMinimap: false, numberColumns: 2, signWidth: 18, showsMarks: false, lineStyles: styles)
  }

  static var sidePresentation: SurfacePresentation {
    SurfacePresentation(showsMinimap: false, showsMarks: false, lineStyles: styles)
  }

  /// 面の見え方——Orbe の見え方の番号の列を見本の寸法（幅 44、右の余白はインライン 6・並列 8）にしたもの。
  static func style(trailing: CGFloat) -> TextSurfaceStyle {
    var style = EditorStyle.make()
    style.gutterWidth = 44
    style.gutterTrailingInset = trailing
    return style
  }
}

extension DiffRowsSample.Row {
  var line: String {
    switch self {
    case .same(let line), .removed(let line), .added(let line): line
    }
  }
}
