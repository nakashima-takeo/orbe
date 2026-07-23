import XCTest

@testable import Orbe

/// 実押下 combo → 行ハイライト（`syncPressedMatch`）の設計を固定する。
/// 一致は正規化済み押下集合と combo の完全一致（同 combo の複数行は全行対象）。
/// 現在のビューに該当行が無ければ「すべて」一覧へ自動遷移し、検索・キー絞り込みが
/// 隠すときだけクリアして必ず見せる。キー解放でハイライトは消えるがビューは戻さない。
final class HelpModelTests: XCTestCase {
  private let l10n = LocalizationStore(language: .ja)

  private func model() -> HelpModel { HelpModel() }

  /// 完全一致だけがハイライトする（修飾のみ・部分一致は対象外）。
  func testExactMatchOnly() {
    let m = model()
    m.pressed = ["cmd"]
    m.syncPressedMatch(l10n)
    XCTAssertTrue(m.pressedRowIDs.isEmpty)
    XCTAssertNil(m.revealRowID)

    m.pressed = ["cmd", "shift"]
    m.syncPressedMatch(l10n)
    XCTAssertTrue(m.pressedRowIDs.isEmpty)

    m.pressed = ["cmd", "t"]
    m.syncPressedMatch(l10n)
    XCTAssertEqual(m.pressedRowIDs, ["top/\(L10nKey.helpCatWorkspaceTabs.rawValue)/⌘T"])
    XCTAssertEqual(m.revealRowID, "top/\(L10nKey.helpCatWorkspaceTabs.rawValue)/⌘T")
  }

  /// 左右修飾キー（rcmd/rshift/ropt）は combo 語彙へ正規化して一致する。
  func testRightModifiersNormalize() {
    let m = model()
    m.category = .all
    m.pressed = ["rcmd", "rshift", "s"]
    m.syncPressedMatch(l10n)
    XCTAssertEqual(m.pressedRowIDs, ["\(L10nKey.helpCatWorkspaceTabs.rawValue)/⌘⇧S"])
  }

  /// 同 combo の複数行（⌘⇧↑ / ⌘⇧↓ = cmd shift ud）は全行ハイライトする。
  func testSameComboLightsAllRows() {
    let m = model()
    m.category = .all
    m.pressed = ["cmd", "shift", "ud"]
    m.syncPressedMatch(l10n)
    XCTAssertEqual(
      m.pressedRowIDs,
      [
        "\(L10nKey.helpCatPanesEditor.rawValue)/⌘⇧↑",
        "\(L10nKey.helpCatPanesEditor.rawValue)/⌘⇧↓",
      ])
    XCTAssertEqual(m.revealRowID, "\(L10nKey.helpCatPanesEditor.rawValue)/⌘⇧↑")
  }

  /// トップビューに該当行があればトップの行 id でハイライトし、ビューは変えない。
  func testTopViewMatchStaysTop() {
    let m = model()
    m.pressed = ["cmd", "shift", "a"]
    m.syncPressedMatch(l10n)
    XCTAssertTrue(m.isTopView)
    XCTAssertEqual(m.pressedRowIDs, ["top/\(L10nKey.helpCatAgents.rawValue)/⌘⇧A"])
  }

  /// トップビューに無い combo（⌘R）は「すべて」一覧へ自動遷移して見せる。
  func testTopViewAutoRevealsToAll() {
    let m = model()
    m.pressed = ["cmd", "r"]
    m.syncPressedMatch(l10n)
    XCTAssertEqual(m.category, .all)
    XCTAssertEqual(m.pressedRowIDs, ["\(L10nKey.helpCatWorkspaceTabs.rawValue)/⌘R"])
  }

  /// 個別カテゴリ表示中に別カテゴリの combo を押すと「すべて」へ遷移する（検索は保つ）。
  func testCategoryAutoRevealsToAllKeepingQuery() {
    let m = model()
    m.category = .group(.helpCatGeneral)
    m.pressed = ["cmd", "t"]
    m.syncPressedMatch(l10n)
    XCTAssertEqual(m.category, .all)
    XCTAssertEqual(m.pressedRowIDs, ["\(L10nKey.helpCatWorkspaceTabs.rawValue)/⌘T"])
  }

  /// 検索・キー絞り込みが該当行を隠すときだけクリアして必ず見せる。
  func testFiltersClearOnlyWhenHiding() {
    // 検索が該当行を含む → クリアしない。
    let keep = model()
    keep.category = .all
    keep.query = "タブ"
    keep.pressed = ["cmd", "t"]
    keep.syncPressedMatch(l10n)
    XCTAssertEqual(keep.query, "タブ")
    XCTAssertEqual(keep.pressedRowIDs, ["\(L10nKey.helpCatWorkspaceTabs.rawValue)/⌘T"])

    // 検索が該当行を隠す → クリアして見せる。
    let clear = model()
    clear.category = .all
    clear.query = "タブ"
    clear.fkey = "t"
    clear.pressed = ["cmd", ","]
    clear.syncPressedMatch(l10n)
    XCTAssertEqual(clear.query, "")
    XCTAssertNil(clear.fkey)
    XCTAssertEqual(clear.pressedRowIDs, ["\(L10nKey.helpCatGeneral.rawValue)/⌘,"])
  }

  /// キー解放でハイライトと reveal は消えるが、自動遷移したビューは戻さない。
  func testReleaseClearsHighlightKeepsView() {
    let m = model()
    m.pressed = ["cmd", "r"]
    m.syncPressedMatch(l10n)
    XCTAssertEqual(m.category, .all)

    m.pressed = []
    m.syncPressedMatch(l10n)
    XCTAssertTrue(m.pressedRowIDs.isEmpty)
    XCTAssertNil(m.revealRowID)
    XCTAssertEqual(m.category, .all)
  }
}
