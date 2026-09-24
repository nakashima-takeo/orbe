import Foundation

/// ハンクから導く行の印——行ごとの「追加／変更」と「この境の下に削除がある」。行は 1 始まり（`LineHunk`
/// と同じ数え方）。文書が持ち、行索引でオフセット区間に写してテキスト面へ渡す（→ `LineMarkSpans`）。俯瞰は
/// 行の連（`runs`）と削除の境（`deletionsBelow`）をそのまま読む。
public struct LineMarks: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case added
    case modified
  }

  /// 同じ印が続く行の区間。ハンクが昇順・非重複（`LineDiff` は両側を単調に進める）なので、そこから写した
  /// run も昇順・非重複。
  public struct Run: Equatable, Sendable {
    /// 1 始まりの行の区間。
    public let lines: Range<Int>
    public let kind: Kind
  }

  public let runs: [Run]
  /// 削除がある境。値 n は「n 行目の下」（0 は先頭行の上）。ハンクの順（昇順）。
  public let deletionsBelow: [Int]

  /// 追加（old 側 0 件）はその新しい行、削除（new 側 0 件）はその境、両側にあれば新しい行が変更。
  public init(hunks: [LineHunk]) {
    var runs: [Run] = []
    var deletions: [Int] = []
    for hunk in hunks {
      if hunk.newCount == 0 {
        deletions.append(hunk.newStart)
      } else {
        runs.append(
          Run(
            lines: hunk.newStart..<(hunk.newStart + hunk.newCount),
            kind: hunk.oldCount == 0 ? .added : .modified))
      }
    }
    self.runs = runs
    deletionsBelow = deletions
  }

  /// 面へ渡す形。行の区間は改行込み（次の行頭まで、末尾なら本文の長さまで）、境は次の行の行頭のオフセット。
  /// 索引に無い行（索引と印が同じ本文から出ている限り起きない）は落とす。
  func spans(in index: LineIndex) -> LineMarkSpans {
    let end = { (row: Int) in row < index.lineCount ? index.start(ofRow: row) : index.length }
    var marks: [LineMarkSpans.Mark] = []
    for run in runs {
      let firstRow = run.lines.lowerBound - 1
      guard firstRow >= 0, firstRow < index.lineCount else { continue }
      let start = index.start(ofRow: firstRow)
      let stop = end(min(run.lines.upperBound - 1, index.lineCount))
      marks.append(
        LineMarkSpans.Mark(
          range: NSRange(location: start, length: max(0, stop - start)), kind: run.kind))
    }
    let deletions = deletionsBelow.map(end)
    return LineMarkSpans(marks: marks, deletions: deletions)
  }
}

/// テキスト面が受け取る行の印（UTF-16 オフセット。契約の他の区間と同じ）。
public struct LineMarkSpans: Equatable, Sendable {
  public struct Mark: Equatable, Sendable {
    /// 行の区間（改行込み）。昇順・重ならない。
    public let range: NSRange
    public let kind: LineMarks.Kind

    public init(range: NSRange, kind: LineMarks.Kind) {
      self.range = range
      self.kind = kind
    }
  }

  public let marks: [Mark]
  /// 削除がある境のオフセット＝次の行の行頭（末尾なら本文の長さ）。昇順。
  public let deletions: [Int]

  public init(marks: [Mark], deletions: [Int]) {
    self.marks = marks
    self.deletions = deletions
  }

  public static let empty = LineMarkSpans(marks: [], deletions: [])

  public var isEmpty: Bool { marks.isEmpty && deletions.isEmpty }
}
