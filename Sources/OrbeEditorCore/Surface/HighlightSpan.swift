import Foundation

/// 役割付きの区間（UTF-16 オフセット）。構文層が発行し、テキスト面が色に写す。
public struct HighlightSpan: Equatable, Sendable {
  public let range: NSRange
  public let role: SyntaxRole

  public init(range: NSRange, role: SyntaxRole) {
    self.range = range
    self.role = role
  }
}
