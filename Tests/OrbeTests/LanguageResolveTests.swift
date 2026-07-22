import XCTest

@testable import Orbe

/// OS 言語コード → UI 言語の分類規則（`Language.resolve`）を固定する。`systemDefault` は環境依存で
/// 決定的に検証できないため、分類規則だけを純関数 seam に切り出して突く。回帰例＝`hasPrefix` を
/// 完全一致へ変える（"ja-JP" が英語に落ちる）・fallback を取り違える。
final class LanguageResolveTests: XCTestCase {
  func testJapanesePrefixResolvesToJa() {
    XCTAssertEqual(Language.resolve(preferred: "ja"), .ja)
    XCTAssertEqual(Language.resolve(preferred: "ja-JP"), .ja, "地域付きも ja 接頭辞で日本語")
    XCTAssertEqual(Language.resolve(preferred: "ja_JP"), .ja, "アンダースコア区切りも同様")
  }

  func testNonJapaneseResolvesToEn() {
    XCTAssertEqual(Language.resolve(preferred: "en"), .en)
    XCTAssertEqual(Language.resolve(preferred: "en-US"), .en)
    XCTAssertEqual(Language.resolve(preferred: "fr"), .en, "未対応言語は英語へ倒す")
  }

  func testMissingOrEmptyResolvesToEn() {
    XCTAssertEqual(Language.resolve(preferred: nil), .en, "OS 設定が空でも既定は英語")
    XCTAssertEqual(Language.resolve(preferred: ""), .en)
  }
}
