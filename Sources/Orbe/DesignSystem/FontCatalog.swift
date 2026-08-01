import AppKit
import CoreText
import Foundation

/// 利用可能なフォントの family 名を実行時に CoreText で列挙する。
/// ターミナル本文（`names()`）はプロポーショナルフォントを選ぶと表示が破綻するため等幅
/// （monospace trait）のみを出す。タブタイトル（`allNames()`）は制限なしの全 family を出す。
/// 返す family 名は ghostty の `font-family`（family 名で解決）へそのまま渡せる。
enum FontCatalog {
  /// 等幅フォント family 名を case-insensitive 昇順で返す。解決できなければ `[]`（パレットは空状態へ縮退）。
  static func names() -> [String] {
    families(where: isMonospace)
  }

  /// 全フォント family 名（等幅制限なし）を case-insensitive 昇順で返す。タブタイトルフォントの列挙が使う。
  static func allNames() -> [String] {
    families { _ in true }
  }

  /// family 名を厳密解決した NSFont（見つからなければ nil＝呼び出し側が既定へ退避する）。
  /// `NSFont(name:size:)` は PostScript 名解決で family 名を取りこぼすため descriptor マッチングで引く。
  static func resolve(family: String, size: CGFloat) -> NSFont? {
    let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
    guard let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [.family]) else {
      return nil
    }
    return NSFont(descriptor: matched, size: size)
  }

  private static func families(where include: (CTFontDescriptor) -> Bool) -> [String] {
    let collection = CTFontCollectionCreateFromAvailableFonts(nil)
    guard
      let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection)
        as? [CTFontDescriptor]
    else { return [] }

    var families: Set<String> = []
    for descriptor in descriptors {
      guard include(descriptor),
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute)
          as? String
      else { continue }
      families.insert(family)
    }
    return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// descriptor の symbolic trait に monospace が立っているか。
  private static func isMonospace(_ descriptor: CTFontDescriptor) -> Bool {
    guard
      let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
        as? [CFString: Any],
      let symbolic = traits[kCTFontSymbolicTrait] as? UInt32
    else { return false }
    return CTFontSymbolicTraits(rawValue: symbolic).contains(.traitMonoSpace)
  }
}
