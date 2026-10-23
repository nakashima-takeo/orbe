import Foundation

/// ハンクから導く行の印（git ガター）——行の区間ごとの「追加／変更」と、削除がある行の境。行は文書の行（0 始まり。
/// エディターに見える行で、改行で終わる本文の末尾の空の行も 1 行）。文書が今のハンクから作り、テキスト面へ渡す。
public struct LineMarks: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case added
    case modified
  }

  /// 同じ印が続く行の区間。
  public struct Bar: Equatable, Sendable {
    public let rows: ClosedRange<Int>
    public let kind: Kind
  }

  /// 昇順・重ならない（ハンクの形から）。
  public let bars: [Bar]
  /// 削除がある境。値 n は n 行目の上端（0 は先頭行の上、行数なら最後の行の下端）。昇順。
  public let deletions: [Int]

  public static let empty = LineMarks(bars: [], deletions: [])

  public var isEmpty: Bool { bars.isEmpty && deletions.isEmpty }

  init(bars: [Bar], deletions: [Int]) {
    self.bars = bars
    self.deletions = deletions
  }

  /// 追加（old 側 0 件）はその新しい行、削除（new 側 0 件）はその境、両側にあれば新しい行が変更。ハンクは今の本文に対する
  /// `LineDiff` の出力と同じ形（→ `LineDiff`）。
  init(hunks: [LineHunk]) {
    var bars: [Bar] = []
    var deletions: [Int] = []
    for hunk in hunks {
      let rows = hunk.newLines
      guard !rows.isEmpty else {
        deletions.append(rows.lowerBound)
        continue
      }
      bars.append(Bar(rows: rows.lowerBound...(rows.upperBound - 1), kind: hunk.oldCount == 0 ? .added : .modified))
    }
    self.init(bars: bars, deletions: deletions)
  }
}
