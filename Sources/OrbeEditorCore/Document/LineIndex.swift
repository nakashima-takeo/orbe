import Foundation

/// 行頭オフセット（UTF-16）の索引。行は `\n` で区切る（tree-sitter の行の数え方と同じ。`\r\n` は
/// `\n` の側で切れる）。編集ごとに影響行だけを差し替え、以降の行頭を平行移動する。本文の長さも持つ
/// （最後の行の終わり）。
public struct LineIndex: Equatable, Sendable {
  /// 各行の先頭オフセット。`starts[0] == 0`。
  private var starts: [Int]
  /// 本文の UTF-16 長。
  public private(set) var length: Int

  public init(text: String) {
    starts = [0] + Self.lineStarts(in: text, base: 0)
    length = text.utf16.count
  }

  public var lineCount: Int { starts.count }

  /// 0 始まりの行の先頭オフセット。
  public func start(ofRow row: Int) -> Int { starts[row] }

  /// 0 始まりの行の終わり（次の行頭。最後の行なら本文の長さ）。
  public func end(ofRow row: Int) -> Int { row + 1 < starts.count ? starts[row + 1] : length }

  /// オフセットが属する行と、行頭からの距離（UTF-16 単位）。
  public func point(at offset: Int) -> (row: Int, column: Int) {
    let row = rowIndex(containing: offset)
    return (row, offset - starts[row])
  }

  /// 編集を索引へ写す。`edit.range` 内で終わる行を落とし、置換文字列の行を差し込み、以降を平行移動する。
  public mutating func apply(_ edit: TextEdit, replacement: String) {
    let removedEnd = NSMaxRange(edit.range)
    let delta = edit.replacementLength - edit.range.length
    // 行頭 p は p-1 の `\n` に由来する。その `\n` が削除区間に入る行頭（loc < p <= removedEnd）を落とす。
    let firstAffected = starts.firstIndex { $0 > edit.range.location } ?? starts.count
    let firstKept = starts.firstIndex { $0 > removedEnd } ?? starts.count
    let inserted = Self.lineStarts(in: replacement, base: edit.range.location)
    let tail = starts[firstKept...].map { $0 + delta }
    starts.replaceSubrange(firstAffected..., with: inserted + tail)
    length += delta
  }

  private func rowIndex(containing offset: Int) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if starts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    return low
  }

  private static func lineStarts(in text: String, base: Int) -> [Int] {
    var result: [Int] = []
    var offset = base
    for unit in text.utf16 {
      offset += 1
      if unit == 0x0A { result.append(offset) }
    }
    return result
  }
}
