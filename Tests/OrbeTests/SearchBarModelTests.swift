import XCTest

@testable import Orbe

/// 検索の欄の件数の出し方と更新の規則（`SearchBarModel`）。端末のスクロールバック検索のバーとエディターのファイル内検索の欄が、
/// 同じ規則を読む。位置があれば「位置/総数」、位置が無ければエディターは「?/総数」・端末は件数の文（「3 件」の形）、上限で
/// 打ち切れば総数に「+」、一致が無ければ「一致なし」、検索語が空なら件数を出さない。
///
/// 壊れると何が起きるか。件数が出ない・位置が出ない。上限で打ち切ったのに全部の件数に見える。一致が無いのに「0 件」と出て
/// 赤くならない、または検索語を消した後も前の件数が残る。端末とエディターの一方だけを直したつもりで、もう一方の件数が変わる。
@MainActor
final class SearchBarModelTests: OrbeTestCase {
  private let l10n = LocalizationStore(language: .ja)

  /// 検索語を入れた欄の状態（`unknownPosition` は、位置が無いとき「?」を出すか。エディターは出し、端末は出さない）。
  private func model(unknownPosition: Bool = false) -> SearchBarModel {
    let model = SearchBarModel()
    model.needle = "a"
    model.showsUnknownPosition = unknownPosition
    return model
  }

  /// 位置があれば「位置/総数」で、上限で打ち切れば総数に「+」が付く。
  func testWithAPositionTheCountIsPositionOverTotal() {
    let model = model()

    model.updateCount(selected: 2, total: 3)
    XCTAssertEqual(model.countText(l10n), "2/3")
    model.updateCount(selected: 2, total: 3, limited: true)
    XCTAssertEqual(model.countText(l10n), "2/3+", "打ち切り")
  }

  /// 位置（今の一致の番号）が無ければ、エディターは「?/総数」を、端末は件数の文（「3 件」の形）を出す。上限で打ち切れば、
  /// どちらも総数に「+」が付く。
  func testWithoutAPositionTheEditorShowsAQuestionMarkAndTheTerminalTheCount() {
    let editor = model(unknownPosition: true)
    let terminal = model()

    editor.updateCount(selected: nil, total: 3)
    terminal.updateCount(selected: nil, total: 3)
    XCTAssertEqual(editor.countText(l10n), "?/3", "エディター")
    XCTAssertEqual(
      terminal.countText(l10n), l10n.plural(3, one: .searchMatchesOne, other: .searchMatchesOther),
      "端末")

    editor.updateCount(selected: nil, total: 3, limited: true)
    terminal.updateCount(selected: nil, total: 3, limited: true)
    XCTAssertEqual(editor.countText(l10n), "?/3+", "エディターの打ち切り")
    XCTAssertEqual(terminal.countText(l10n), "3+", "端末の打ち切り")
  }

  /// 総数が 0 か無い（端末は負の値を無いとして渡す）なら「一致なし」。検索語が空なら、総数が届いても件数を出さない。
  func testNoMatchSaysSoAndAnEmptyNeedleShowsNoCount() {
    let model = model()

    model.updateCount(selected: nil, total: 0)
    XCTAssertEqual(model.countText(l10n), l10n.string(.searchNoMatch))
    XCTAssertTrue(model.countIsNoMatch, "一致なしは警告の色")
    model.updateCount(selected: nil, total: nil)
    XCTAssertEqual(model.countText(l10n), l10n.string(.searchNoMatch), "総数が無い")

    model.needle = ""
    model.updateCount(selected: 1, total: 3)
    XCTAssertNil(model.countText(l10n), "検索語が空なら出さない")
    XCTAssertFalse(model.countIsNoMatch)
  }
}
