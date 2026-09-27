import CoreFoundation
import Foundation
import OrbeEditorCore

/// 編集の規則が本文の写しに問う、行と書記素の境。どれも位置の前後の小さな窓だけを読み、文書の大きさに依らない。
extension TextRope {
  /// 書記素の境を探すために、位置の前後それぞれに読む単位の数。
  private static let clusterWindow = 64

  /// 行の中身の区間（行末の改行と、その前の `\r` を除く）。
  func contentRange(ofRow row: Int) -> NSRange {
    let start = lineStart(row)
    var end = row + 1 < lineCount ? lineStart(row + 1) - 1 : length
    if end > start, unit(at: end - 1) == 0x0D { end -= 1 }
    return NSRange(location: start, length: end - start)
  }

  /// 位置の単位（本文の外なら nil）。
  func unit(at offset: Int) -> UInt16? {
    guard offset >= 0, offset < length else { return nil }
    return units(in: NSRange(location: offset, length: 1)).first
  }

  /// `offset` を含む書記素（OS の合成文字の単位）の区間。行末の `\r\n` は 1 つとして扱う。
  func grapheme(containing offset: Int) -> NSRange {
    guard offset >= 0, offset < length else { return NSRange(location: offset, length: 0) }
    let start = max(0, offset - Self.clusterWindow)
    let window = units(
      in: NSRange(location: start, length: min(length, offset + Self.clusterWindow) - start))
    let range = window.withUnsafeBufferPointer { buffer in
      let string = CFStringCreateWithCharactersNoCopy(
        nil, buffer.baseAddress, buffer.count, kCFAllocatorNull)!
      return CFStringGetRangeOfComposedCharactersAtIndex(string, offset - start)
    }
    var result = NSRange(location: start + range.location, length: range.length)
    if unit(at: result.location) == 0x0A, unit(at: result.location - 1) == 0x0D {
      result = NSRange(location: result.location - 1, length: result.length + 1)
    } else if unit(at: NSMaxRange(result) - 1) == 0x0D, unit(at: NSMaxRange(result)) == 0x0A {
      result.length += 1
    }
    return result
  }

  /// `offset` より後ろの最初の書記素の境（末尾なら末尾）。
  func nextBoundary(after offset: Int) -> Int {
    offset >= length ? length : NSMaxRange(grapheme(containing: offset))
  }

  /// `offset` より前の最後の書記素の境（先頭なら 0）。
  func previousBoundary(before offset: Int) -> Int {
    offset <= 0 ? 0 : grapheme(containing: offset - 1).location
  }

  /// ⌫ で消す区間の始まり（macOS の後ろ向きの削除の単位）——前の書記素が絵文字の並び（ZWJ・国旗・肌の色・異体字の
  /// 選択・キーキャップ）か `\r\n` か 1 つの字なら書記素ごと、そうでなければ最後の字だけ（分解した濁点・結合文字・
  /// ハングルの字母・インドの結合子は 1 つずつ消える）。
  func backwardDeletionStart(before offset: Int) -> Int {
    guard offset > 0 else { return 0 }
    let cluster = grapheme(containing: offset - 1)
    let units = units(in: NSRange(location: cluster.location, length: offset - cluster.location))
    let scalars = Array(String(decoding: units, as: UTF16.self).unicodeScalars)
    guard scalars.count > 1, units != [0x0D, 0x0A], !scalars.contains(where: Self.isEmojiPart)
    else { return cluster.location }
    return offset - scalars.last!.utf16.count
  }

  private static func isEmojiPart(_ scalar: Unicode.Scalar) -> Bool {
    let properties = scalar.properties
    return properties.isEmojiPresentation || properties.isEmojiModifier
      || (0x1F1E6...0x1F1FF).contains(scalar.value) || [0x200D, 0xFE0F, 0x20E3].contains(scalar.value)
  }
}
