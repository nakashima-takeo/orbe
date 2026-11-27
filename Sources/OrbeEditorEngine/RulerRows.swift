import Foundation
import OrbeEditorCore

/// 検索の一致と語の出現を行へ写した結果を覚える（描画スレッドだけ）。本文の編集では、覚えた区間と行を同じ編集でずらし、
/// 届いた区間の列がずらした列と同じなら行もずらしたものを使い回す（打鍵のたびに EditorSearch が一致をずらして押し直しても、
/// 1MB・19999 件を写し直さない）。写し直すのは区間の列が本当に変わったとき（検索語を変えた）だけ。
final class RulerRows {
  /// 行へ写した区間——区間と、同じ順の行。
  struct Mapped {
    var ranges: [NSRange] = []
    var rows: [ClosedRange<Int>] = []
    /// 置き直された列の回数（`Highlights` の版）。
    var revision = -1
    /// 行を写し直した・ずらした回数（印の図形を作り直すかの判断）。
    var generation = 0
  }

  private var find = Mapped()
  private var word = Mapped()
  /// このコマで写し直した区間の数（計測）。
  private(set) var remappedInFrame = 0

  /// 本文の編集を受け取り、覚えた区間と行をずらす。
  func receive(_ edits: [RowEdit]) {
    for edit in edits where !edit.rolesOnly {
      Self.shift(&find, by: edit)
      Self.shift(&word, by: edit)
    }
  }

  /// 検索の一致を行へ写したもの。
  func find(_ highlights: Highlights, text: TextRope) -> Mapped {
    remappedInFrame = 0
    update(&find, highlights.find, revision: highlights.findRevision, text: text)
    return find
  }

  /// 語の出現を行へ写したもの。
  func word(_ highlights: Highlights, text: TextRope) -> Mapped {
    update(&word, highlights.word, revision: highlights.wordRevision, text: text)
    return word
  }

  private func update(_ mapped: inout Mapped, _ ranges: [NSRange], revision: Int, text: TextRope) {
    guard revision != mapped.revision else { return }
    mapped.revision = revision
    guard ranges != mapped.ranges else { return }
    mapped.ranges = ranges
    mapped.rows = text.rows(ofAscending: ranges)
    mapped.generation += 1
    remappedInFrame += ranges.count
  }

  /// 編集の後の本文へずらす——編集より前はそのまま、後ろは平行移動（行は増減した行の数だけ）、編集に掛かる区間は落とす
  /// （`TextEdit.track` と同じ規則）。全部の行が変わった編集では覚えたものを捨てる。
  private static func shift(_ mapped: inout Mapped, by edit: RowEdit) {
    guard !mapped.ranges.isEmpty else { return }
    guard let change = edit.text else {
      mapped = Mapped(revision: -1, generation: mapped.generation + 1)
      return
    }
    let range = change.range
    let delta = change.replacementLength - range.length
    let rowDelta = edit.inserted - edit.rows.count
    var ranges: [NSRange] = []
    var rows: [ClosedRange<Int>] = []
    ranges.reserveCapacity(mapped.ranges.count)
    rows.reserveCapacity(mapped.rows.count)
    for (item, row) in zip(mapped.ranges, mapped.rows) {
      if NSMaxRange(item) <= range.location {
        ranges.append(item)
        rows.append(row)
      } else if item.location >= NSMaxRange(range) {
        ranges.append(NSRange(location: item.location + delta, length: item.length))
        rows.append((row.lowerBound + rowDelta)...(row.upperBound + rowDelta))
      }
    }
    mapped.ranges = ranges
    mapped.rows = rows
    mapped.generation += 1
  }
}

/// 印の図形の元（行・行数・高さ・倍率）が変わったときだけ、印の縦の区間を作り直して覚える。
struct RulerSpans {
  struct Key: Equatable {
    var find: Int
    var word: Int
    var marks: LineMarks
    var lineCount: Int
    /// 縦の並びの版（行を表示の単位へ写す）。
    var rows: Int
    var scrollLines: CGFloat
    var visibleLines: CGFloat
    var height: CGFloat
    var scale: CGFloat
    var current: NSRange?
  }

  var key: Key?
  /// 色ごとの縦の区間（描く順）。
  var groups: [(kind: Kind, spans: [OverviewRuler.Span])] = []

  /// キャレットの印の元（キャレットの列が同じなら、止まっている間の点滅のコマで作り直さない）。
  struct CaretKey: Equatable {
    var carets: [Int]
    var upstream: [Int]
    /// 本文の版（同じオフセットのキャレットでも、本文が変われば行が変わりうる）と縦の並びの版。
    var version: Int
    var rows: Int
    var scrollLines: CGFloat
    var visibleLines: CGFloat
    var height: CGFloat
    var scale: CGFloat
  }

  var caretKey: CaretKey?
  /// キャレットの印の縦の区間（重なるものはまとめた、上から順）。
  var caretSpans: [OverviewRuler.Span] = []

  /// 印の種類（色とレーン）。
  enum Kind {
    case added, modified, removed, word, find

    /// git は左、検索の一致と語の出現は中央。
    var lane: OverviewRuler.Lane {
      switch self {
      case .added, .modified, .removed: .left
      case .word, .find: .center
      }
    }
  }
}
