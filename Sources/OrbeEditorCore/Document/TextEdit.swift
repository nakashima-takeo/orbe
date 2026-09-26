import Foundation

/// テキスト面で起きた 1 回の置換。`range` は変更前の本文での区間、`replacement` は置換後の中身の UTF-16 の単位で、
/// `replacementLength` はその長さ（tree-sitter の既定符号化と一致する）。中身を Swift の文字列でなく単位で運ぶのは、
/// 面の本文がサロゲートの対の片割れを持ちうるから（対を割る置換とその undo）——文字列にすると片割れが U+FFFD に化け、
/// 写しが面の本文からずれる。
public struct TextEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacement: ContiguousArray<UInt16>
  public var replacementLength: Int { replacement.count }

  public init(range: NSRange, replacement: ContiguousArray<UInt16>) {
    self.range = range
    self.replacement = replacement
  }

  public init(range: NSRange, replacement: String) {
    self.init(range: range, replacement: ContiguousArray(replacement.utf16))
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

  /// 置換の前後で変わらない先頭と末尾を落とした編集——本文が実際に変わった最小の区間。`old` は置き換える前の区間の
  /// 単位。サロゲートの対は割らない。
  public func narrowed(replacing old: ContiguousArray<UInt16>) -> TextEdit {
    guard !old.isEmpty, replacementLength > 0 else { return self }
    let new = replacement
    let limit = min(old.count, new.count)
    var prefix = 0
    while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
    if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
    var suffix = 0
    while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
      suffix += 1
    }
    if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
    guard prefix > 0 || suffix > 0 else { return self }
    return TextEdit(
      range: NSRange(location: range.location + prefix, length: old.count - prefix - suffix),
      replacement: ContiguousArray(new[prefix..<(new.count - suffix)]))
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
