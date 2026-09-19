import Foundation

/// 俯瞰（ミニマップ）の行 1 つの縮図——インデントの桁・本文の桁数・コメント行か。文字を矩形に置き換えて描く
/// ための値で、面の座標も色も持たない。
public struct OverviewRow: Equatable, Sendable {
  /// 行頭の空白の桁（スペース 1・タブは `tabWidth`）。
  public let indent: Int
  /// 行頭・行末の空白を除いた UTF-16 長。0 は空行（描かない）。
  public let length: Int
  /// 最初の非空白文字が comment 役割の区間に入る。
  public let isComment: Bool

  public init(indent: Int, length: Int, isComment: Bool) {
    self.indent = indent
    self.length = length
    self.isComment = isComment
  }
}

public enum OverviewRows {
  /// `lines`（0 始まりの行の窓）の縮図。`text` は窓の本文（先頭行の行頭から）、`commentRanges` は本文全体の
  /// オフセットで表した comment 役割の区間（昇順）。
  public static func rows(
    lines: Range<Int>, text: String, index: LineIndex, tabWidth: Int, commentRanges: [NSRange]
  ) -> [OverviewRow] {
    guard !lines.isEmpty, lines.upperBound <= index.lineCount else { return [] }
    let units = Array(text.utf16)
    let base = index.start(ofRow: lines.lowerBound)
    var comment = 0
    return lines.map { row in
      let start = index.start(ofRow: row) - base
      let end = min(index.end(ofRow: row) - base, units.count)
      var head = start
      var indent = 0
      while head < end, isBlank(units[head]) {
        indent += units[head] == 0x09 ? tabWidth : 1
        head += 1
      }
      var tail = end
      while tail > head, isBlank(units[tail - 1]) { tail -= 1 }
      guard head < tail else { return OverviewRow(indent: 0, length: 0, isComment: false) }
      let first = base + head
      while comment < commentRanges.count, NSMaxRange(commentRanges[comment]) <= first {
        comment += 1
      }
      let isComment =
        comment < commentRanges.count && NSLocationInRange(first, commentRanges[comment])
      return OverviewRow(indent: indent, length: tail - head, isComment: isComment)
    }
  }

  private static func isBlank(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0D || unit == 0x0A
  }
}
