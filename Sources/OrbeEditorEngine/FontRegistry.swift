import CoreText

/// アトラスがフォントに振る番号。組版の結果に出たフォント（代替フォントを含む）を、名前と大きさで見分ける。描画スレッドの
/// 持ち物で（倍率ごとのアトラスが共有する）、スレッドの外には出ない。
final class FontRegistry {
  private var fonts: [(font: CTFont, isColor: Bool)] = []
  private var index: [String: UInt16] = [:]

  func id(_ font: CTFont) -> UInt16 {
    let key = "\(CTFontCopyPostScriptName(font) as String)@\(CTFontGetSize(font))"
    if let id = index[key] { return id }
    let id = UInt16(fonts.count)
    fonts.append((font, CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)))
    index[key] = id
    return id
  }

  func font(_ id: UInt16) -> (font: CTFont, isColor: Bool) { fonts[Int(id)] }

  /// 色付きのグリフのフォントか（字ごとに引くので、フォントを持ち出さない）。
  func isColor(_ id: UInt16) -> Bool { fonts[Int(id)].isColor }
}
