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

  /// ⌫ で消す区間の始まり（macOS の後ろ向きの削除の単位。NSTextView と同じ）。規則は CoreFoundation の後ろ向きの削除の
  /// 範囲（swift-corelibs-foundation の `CFString.c`、`_CFStringInlineBufferGetComposedRange` の
  /// `kCFStringBackwardDeletionCluster`）の移植——前の書記素（OS の合成文字の単位）を後ろから見て、アルメニア文字〜リンブ
  /// 文字（U+0530–U+194F。インド系・タイ・アラビア・ヘブライなど）の字に当たればその字から消し、結合の記号なら前へ進み、
  /// それ以外の字に当たれば書記素ごと消す。ハングルの字母は書記素ごと。分解した濁点・アクセント・異体字の選択子・絵文字の
  /// 並び・国旗・`\r\n` は書記素ごと、インド系の母音記号やアラビア・ヘブライの記号は 1 つずつ消える。
  func backwardDeletionStart(before offset: Int) -> Int {
    guard offset > 0 else { return 0 }
    let cluster = grapheme(containing: offset - 1)
    let units = units(in: NSRange(location: cluster.location, length: offset - cluster.location))
    var start = offset
    for scalar in String(decoding: units, as: UTF16.self).unicodeScalars.reversed() {
      start -= scalar.utf16.count
      if Self.isHangul(scalar) { return cluster.location }
      if Self.isArmenianToLimbu(scalar) { return start }
      if !Self.extendsBackward(scalar) { return cluster.location }
    }
    return cluster.location
  }

  /// 後ろ向きの削除で前の字と結ばない範囲（CF の同じ規則の範囲）。
  private static func isArmenianToLimbu(_ scalar: Unicode.Scalar) -> Bool {
    (0x0530..<0x1950).contains(scalar.value)
  }

  /// ハングルの字母と音節（CF は後ろ向きの削除でも音節の規則で結ぶ）。
  private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
    (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7A3).contains(scalar.value)
  }

  /// 前の字と結ぶ字——結合の記号（CF の非基底字）、肌の色、タグ、半角の濁点・半濁点、異体字のタグ。
  private static func extendsBackward(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: break
    }
    let value = scalar.value
    return (0x1F3FB...0x1F3FF).contains(value) || (0xE0020...0xE007F).contains(value)
      || value == 0xFF9E || value == 0xFF9F || value & 0x1F_FFF0 == 0xF870
  }
}
