import XCTest

@testable import Orbe

/// `LocalizationStore` の複数形分岐と書式差し込みを固定する。網羅（全キーが非空）は
/// `L10nCompletenessTests` が別途保証するため、ここは「件数で one/other を選ぶ」「引数を
/// 各言語テンプレートの位置へ埋める」という振る舞いだけを突く。
final class LocalizationStoreTests: XCTestCase {

  private func store(_ language: Language) -> LocalizationStore {
    LocalizationStore(language: language)
  }

  // MARK: plural（英語の one/other 分岐・日本語の単複不変）

  /// 英語は count==1 の境界だけ `one`、0 と 2 以上は `other`。
  func testEnglishPluralSwitchesOnCountOne() {
    let s = store(.en)
    XCTAssertEqual(
      s.plural(1, one: .searchMatchesOne, other: .searchMatchesOther), "1 match",
      "count==1 は one（単数形）")
    XCTAssertEqual(
      s.plural(0, one: .searchMatchesOne, other: .searchMatchesOther), "0 matches",
      "count==0 は other（英語は 0 も複数扱い）")
    XCTAssertEqual(
      s.plural(2, one: .searchMatchesOne, other: .searchMatchesOther), "2 matches",
      "count>1 は other")
  }

  /// 日本語は助数詞で単複不変＝one/other が同一テンプレートで、件数だけが変わる。
  func testJapanesePluralIsInvariant() {
    let s = store(.ja)
    XCTAssertEqual(
      L10n.string(.searchMatchesOne, .ja), L10n.string(.searchMatchesOther, .ja),
      "日本語は one と other が同一文言（単複不変）")
    XCTAssertEqual(s.plural(1, one: .searchMatchesOne, other: .searchMatchesOther), "1 件")
    XCTAssertEqual(s.plural(2, one: .searchMatchesOne, other: .searchMatchesOther), "2 件")
  }

  // MARK: format（語順が食い違う書式テンプレート）

  /// 同一引数が、日本語では先頭・英語では末尾に来る。format は各言語テンプレート内の位置へ埋める。
  func testFormatPlacesArgPerLanguageWordOrder() {
    XCTAssertEqual(store(.ja).format(.dispatchAgentOpen, "claude"), "claudeで開く")
    XCTAssertEqual(store(.en).format(.dispatchAgentOpen, "claude"), "open with claude")
  }
}
