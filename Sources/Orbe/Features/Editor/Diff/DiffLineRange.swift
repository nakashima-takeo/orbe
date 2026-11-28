import Foundation

/// diff の 1 行——側と、その側の版の行（0 始まり）。
struct DiffLine: Hashable {
  let version: DiffRows.Version
  let line: Int
}

/// diff の行の範囲（0 始まり）——終わりの行と、始まりの行（1 行なら nil）。PR のコメントの位置（書きかけ・欄の置き場所・並びの
/// 注記）が持つ。作る口は 1 つで、始まりと終わりが同じ行なら始まりを持たない。欄とスレッドの絵は、終わりの行の下に置く。
struct DiffLineRange: Hashable {
  let start: DiffLine?
  let end: DiffLine

  init(start: DiffLine?, end: DiffLine) {
    self.start = start == end ? nil : start
    self.end = end
  }

  /// 始まりの行（1 行なら終わりの行）。
  var first: DiffLine { start ?? end }
}

/// GitHub の行（1 始まり）と diff の行（0 始まり）の相互の変換——行の数え方を変えるのは、ここの 2 つだけ。
extension DiffLineRange {
  init(_ lines: GitHubLineRange) {
    let line = { (line: GitHubLine) in
      DiffLine(version: line.side == .old ? .old : .new, line: line.line - 1)
    }
    self.init(start: lines.start.map(line), end: line(lines.end))
  }
}

extension GitHubLineRange {
  init(_ range: DiffLineRange) {
    let line = { (line: DiffLine) in
      GitHubLine(side: line.version == .old ? .old : .new, line: line.line + 1)
    }
    self.init(start: range.start.map(line), end: line(range.end))
  }
}
