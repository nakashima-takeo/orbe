import Foundation

/// ハンクから導く行の印（git ガター）——行の区間ごとの「追加／変更」と、削除がある行の境。行は文書の行（0 始まり。
/// エディターに見える行で、改行で終わる本文の末尾の空の行も 1 行）。文書がそのときの本文の行に収めて作り、テキスト面へ渡す。
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

  /// 昇順・重ならない（`LineDiff` は両側を単調に進める）。
  public let bars: [Bar]
  /// 削除がある境。値 n は n 行目の上端（0 は先頭行の上、行数なら最後の行の下端）。昇順。
  public let deletions: [Int]

  public static let empty = LineMarks(bars: [], deletions: [])

  public var isEmpty: Bool { bars.isEmpty && deletions.isEmpty }

  init(bars: [Bar], deletions: [Int]) {
    self.bars = bars
    self.deletions = deletions
  }

  /// 追加（old 側 0 件）はその新しい行、削除（new 側 0 件）はその境、両側にあれば新しい行が変更。`lineCount` 行の本文に
  /// 無い行（ずらした前のハンクが本文の外を指すとき）は落とす。
  init(hunks: [LineHunk], lineCount: Int) {
    var bars: [Bar] = []
    var deletions: [Int] = []
    for hunk in hunks {
      if hunk.newCount == 0 {
        deletions.append(min(hunk.newStart, lineCount))
        continue
      }
      let first = hunk.newStart - 1
      guard first >= 0, first < lineCount else { continue }
      let last = min(hunk.newStart + hunk.newCount - 1, lineCount) - 1
      bars.append(Bar(rows: first...last, kind: hunk.oldCount == 0 ? .added : .modified))
    }
    self.init(bars: bars, deletions: deletions)
  }
}
