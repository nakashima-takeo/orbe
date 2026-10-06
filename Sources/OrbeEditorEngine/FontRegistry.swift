import CoreText

/// アトラスがフォントに振る番号。組版の結果に出たフォント（代替フォントを含む）を、名前と大きさで見分ける。描画スレッドの
/// 持ち物で（倍率ごとのアトラスが共有する）、スレッドの外には出ない。
final class FontRegistry {
  private var fonts: [(font: CTFont, isColor: Bool)] = []
  private var index: [String: UInt16] = [:]
  /// 同じフォントの値を毎コマ引く口（区画の字）のための、値の同一性で引く表（値を持って同一性の使い回しを防ぐ）。
  private var instances: [ObjectIdentifier: (font: CTFont, id: UInt16)] = [:]
  private static let instanceLimit = 256

  func id(_ font: CTFont) -> UInt16 {
    let key = "\(CTFontCopyPostScriptName(font) as String)@\(CTFontGetSize(font))"
    if let id = index[key] { return id }
    let id = UInt16(fonts.count)
    fonts.append((font, CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)))
    index[key] = id
    return id
  }

  /// `id(_:)` と同じ番号を、同じ値なら名前を作らずに引く。
  func id(instance font: CTFont) -> UInt16 {
    let object = ObjectIdentifier(font)
    if let hit = instances[object] { return hit.id }
    if instances.count >= Self.instanceLimit { instances.removeAll() }
    let id = id(font)
    instances[object] = (font, id)
    return id
  }

  func font(_ id: UInt16) -> (font: CTFont, isColor: Bool) { fonts[Int(id)] }

  /// 色付きのグリフのフォントか（字ごとに引くので、フォントを持ち出さない）。
  func isColor(_ id: UInt16) -> Bool { fonts[Int(id)].isColor }
}
