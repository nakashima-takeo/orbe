import Foundation

/// 文書の改行の作法——LF か CRLF。文書が本文から検出して面へ押し、編集する面は Enter で入れる改行と、貼る・落とす文字列の
/// 改行をこれに揃える。
public enum LineBreak: Equatable, Sendable {
  case lf, crlf

  public var string: String { self == .lf ? "\n" : "\r\n" }

  /// 本文の UTF-16 単位を先頭から 1 度だけ読む。CRLF と（CR の付かない）LF の数の多い方。同数と改行の無い本文は LF。
  public static func detect(in units: some Sequence<UInt16>) -> LineBreak {
    var crlf = 0
    var lf = 0
    var previous: UInt16 = 0
    for unit in units {
      if unit == 0x0A {
        if previous == 0x0D { crlf += 1 } else { lf += 1 }
      }
      previous = unit
    }
    return crlf > lf ? .crlf : .lf
  }

  /// 文字列の改行（`\r\n`・`\r`・`\n`）をこの作法へ揃える。
  public func normalize(_ string: String) -> String {
    guard string.utf16.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return string }
    var result = String.UnicodeScalarView()
    var scalars = string.unicodeScalars.makeIterator()
    var pending = scalars.next()
    while let scalar = pending {
      pending = scalars.next()
      switch scalar {
      case "\r":
        if pending == "\n" { pending = scalars.next() }
        result.append(contentsOf: self.string.unicodeScalars)
      case "\n":
        result.append(contentsOf: self.string.unicodeScalars)
      default:
        result.append(scalar)
      }
    }
    return String(result)
  }
}
