import Foundation

/// テキスト面で起きた 1 回の置換。`range` は変更前の本文での区間、`replacement` は置換後の文字列で、`replacementLength`
/// はその長さ（どちらも UTF-16。tree-sitter の既定符号化と一致する）。
public struct TextEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacement: String
  public let replacementLength: Int

  public init(range: NSRange, replacement: String) {
    self.range = range
    self.replacement = replacement
    replacementLength = replacement.utf16.count
  }

  /// 置換後の本文での、置き換わった区間。
  public var newRange: NSRange { NSRange(location: range.location, length: replacementLength) }

  /// 編集の前の区間の列（昇順）を編集の後の本文へ写す——編集より前はそのまま、後ろは平行移動し、編集に掛かる区間は
  /// 落とす（取り直すまでの間、地が字からずれて見えないようにする）。
  public func track(_ ranges: [NSRange]) -> [NSRange] {
    let delta = replacementLength - range.length
    return ranges.compactMap { item in
      if NSMaxRange(item) <= range.location { return item }
      if item.location >= NSMaxRange(range) {
        return NSRange(location: item.location + delta, length: item.length)
      }
      return nil
    }
  }

  /// 編集の前の区間の集合を編集の後の本文へ写す。`track` と違い落とさない——編集に掛かる（接する）なら、置換後の区間を
  /// 足す（「まだ作り直していない」「変わった」の集合を、編集に合わせて広げる）。
  public func track(_ set: IndexSet) -> IndexSet {
    let end = NSMaxRange(range)
    let touches = set.intersects(integersIn: max(0, range.location - 1)..<(end + 1))
    var result = set
    result.remove(integersIn: range.location..<end)
    result.shift(startingAt: end, by: replacementLength - range.length)
    if touches, replacementLength > 0 {
      result.insert(integersIn: range.location..<(range.location + replacementLength))
    }
    return result
  }
}
