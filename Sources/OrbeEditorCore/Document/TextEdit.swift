import Foundation

/// テキスト面で起きた 1 回の置換。`range` は変更前の本文での区間、`replacementLength` は置換後の長さ
/// （どちらも UTF-16。tree-sitter の既定符号化と一致する）。
public struct TextEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacementLength: Int

  public init(range: NSRange, replacementLength: Int) {
    self.range = range
    self.replacementLength = replacementLength
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
}

/// 本文が変わった後に文書が告げる「何が変わったか」——編集と、役割が変わりうる区間（構文木の差分。文法が無ければ
/// 置換後の区間）。オフセットは変わった後の本文のもの。俯瞰が縮図の捨てる範囲を絞るのに使う。
public struct TextChange: Equatable, Sendable {
  public let edit: TextEdit
  public let changedRoles: IndexSet

  public init(edit: TextEdit, changedRoles: IndexSet) {
    self.edit = edit
    self.changedRoles = changedRoles
  }
}
