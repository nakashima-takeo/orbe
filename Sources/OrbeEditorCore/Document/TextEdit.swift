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
}
