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
    var (oldNumber, newNext) = (1, 0)
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
        removed.append(InsertedLine(line, style: Self.removed, number: oldNumber))
        oldNumber += 1
      case .added:
        flush()
        open(Self.added, other: nil)
        newNext += 1
      case .same:
        flush()
        open(Self.context, other: oldNumber)
        oldNumber += 1
        newNext += 1
      }
    }
    flush()
    return SurfaceRows(insertions: insertions, spans: spans)
  }

  /// 並列の片側——変わった区間（続く削除と追加）は、削除と追加を上から同じ行に並べ、行の数の差の分だけ短い側の区間の後に
  /// 詰め物の行を差し込む（見本の `diffLeft` / `diffRight` と VS Code の並列と同じ揃え方）。自分の側の変わった行に型を付ける。
  func side(_ side: Side) -> SurfaceRows {
    var insertions: [RowInsertion] = []
    var spans: [LineSpan] = []
    var next = 0
    var last: Int?
    func own(_ count: Int, _ style: Int) {
      guard count > 0 else { return }
      if last != style { spans.append(LineSpan(line: next, style: style)) }
      last = style
      next += count
    }
    for block in blocks {
      switch block {
      case .same(let count): own(count, Self.context)
      case .changed(let removed, let added):
        let (mine, theirs) = side == .old ? (removed, added) : (added, removed)
        own(mine, side == .old ? Self.removed : Self.added)
        guard theirs > mine else { continue }
        let pads = (mine..<theirs).map { _ in InsertedLine("", style: Self.pad) }
        insertions.append(RowInsertion(line: next, content: .lines(pads)))
      }
    }
    return SurfaceRows(insertions: insertions, spans: spans)
  }

  /// 並びの塊——続く同じ行の数か、変わった区間（続く削除と追加。どちらかは 0 でよい）の削除と追加の数。
  enum Block: Equatable {
    case same(Int)
    case changed(removed: Int, added: Int)
  }

  var blocks: [Block] {
    var result: [Block] = []
    for row in rows {
      switch (row, result.last) {
      case (.same, .same(let count)?): result[result.count - 1] = .same(count + 1)
      case (.same, _): result.append(.same(1))
      case (.removed, .changed(let removed, let added)?):
        result[result.count - 1] = .changed(removed: removed + 1, added: added)
      case (.added, .changed(let removed, let added)?):
        result[result.count - 1] = .changed(removed: removed, added: added + 1)
      case (.removed, _): result.append(.changed(removed: 1, added: 0))
      case (.added, _): result.append(.changed(removed: 0, added: 1))
      }
    }
    return result
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

  /// 行の型——追加・削除（地は diffAdded / diffRemoved の 0.12、字は diffAddedText / diffRemovedText、記号は + / −）・文脈
  /// （字は muted）・詰め物（地は fill(0.02)）。
  static var styles: [LineStyle] {
    [
      LineStyle(
        background: Theme.Color.diffAdded.withAlphaComponent(0.12),
        text: Theme.Color.diffAddedText, sign: "+", signColor: Theme.Color.diffAdded),
      LineStyle(
        background: Theme.Color.diffRemoved.withAlphaComponent(0.12),
        text: Theme.Color.diffRemovedText, sign: "−", signColor: Theme.Color.diffRemoved),
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
