import XCTest

@testable import Orbe

/// 辞書がキーとともに腐らないことを機械検出する関門。`L10nKey`（`CaseIterable`）の全 case が
/// `L10n.table` に載り、日英とも非空であることを保証する（欠落キー・空訳を CI で弾く）。
final class L10nCompletenessTests: XCTestCase {
  func testEveryKeyHasNonEmptyJapaneseAndEnglish() {
    for key in L10nKey.allCases {
      guard let entry = L10n.table[key] else {
        XCTFail("L10n.table に \(key) が無い")
        continue
      }
      XCTAssertFalse(
        entry.ja.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) の ja が空")
      XCTAssertFalse(
        entry.en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) の en が空")
    }
  }

  /// 両言語のルックアップが実際に引ける（force-unwrap の安全性を全 case で確認）。
  func testLookupResolvesForBothLanguages() {
    for key in L10nKey.allCases {
      XCTAssertFalse(L10n.string(key, .ja).isEmpty, "\(key) .ja の解決が空")
      XCTAssertFalse(L10n.string(key, .en).isEmpty, "\(key) .en の解決が空")
    }
  }
}
