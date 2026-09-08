import XCTest

@testable import Orbe

/// 一覧末尾に常設する作成導線行（＋ 新規ワークスペース）。絞り込みに関わらず 1 本だけ並び、
/// 入力欄の文字列が既存名と完全一致しなければ、それを行ラベルへ映して作成フォームへ引き継ぐ。
extension WorkspacePaletteTests {
  // MARK: - 末尾常設の「＋ 新規ワークスペース」行

  func testTypingNonMatchingNameThenEnterOpensCreateFlowWithSeed() {
    let p = palette()
    var seed: String??
    var switched: Int?
    p.onCreateFlow = { seed = $0 }
    p.onSwitch = { switched = $0 }
    p.setItems(items([("default", true), ("api", false)]))
    type(p, "infra")  // 一致なし → 残るのは末尾の作成導線行のみ
    send(p, enter)
    XCTAssertEqual(seed, "infra", "一致しない入力の Enter は作成フォームへ 'infra' を引き継ぐ")
    XCTAssertNil(switched, "一致しない名前では switch しない")
  }

  func testExactMatchCreateFlowRowCarriesNoSeed() {
    let p = palette()
    var seed: String??
    var switched: Int?
    p.onCreateFlow = { seed = $0 }
    p.onSwitch = { switched = $0 }
    p.setItems(items([("default", true), ("api", false)]))
    type(p, "api")
    send(p, enter)
    XCTAssertEqual(switched, 1, "完全一致名の Enter は switch")
    send(p, down)  // 一致行の次＝末尾の作成導線行
    send(p, enter)
    XCTAssertEqual(seed, .some(nil), "完全同名があるときは名前を引き継がない")
  }

  func testCreateFlowRowAlwaysPresentAndFiresCallback() {
    let p = palette()
    var createFlow = false
    p.onCreateFlow = { _ in createFlow = true }
    p.setItems(items([("default", true), ("api", false)]))
    let last = p.render.rows.last
    XCTAssertEqual(last?.createStyle, true, "末尾は作成導線の行スタイル")
    send(p, down)  // api
    send(p, down)  // createFlow
    send(p, enter)
    XCTAssertTrue(createFlow, "createFlow 行の Enter は onCreateFlow")
  }

  func testCreateFlowRowSurvivesFiltering() {
    let p = palette()
    p.setItems(items([("default", true), ("api", false)]))
    type(p, "zzz")  // 一致なし → 作成導線行だけが残る
    XCTAssertEqual(p.render.rows.count, 1, "一致ゼロでも作成導線行は 1 本残る")
    XCTAssertEqual(p.render.rows.last?.createStyle, true, "絞り込み中も createFlow は末尾に残る")
  }

  /// 引き継ぐ名前の有無で行ラベルが 2 態に変わる（行は常に 1 本）。
  func testCreateFlowRowLabelCarriesSeedName() {
    let p = palette()
    p.setItems(items([("default", true), ("api", false)]))
    XCTAssertEqual(
      p.render.rows.last?.label, "＋ 新規ワークスペース — パスから作成", "入力が空なら素の文言")
    type(p, "infra")
    XCTAssertEqual(
      p.render.rows.last?.label, "＋ 新規ワークスペース \"infra\" — パスから作成",
      "一致しない入力は行ラベルに現れる")
    XCTAssertEqual(p.render.rows.count, 1, "作成行は 1 本だけ（別行を増やさない）")
  }

  func testRightArrowOnCreateRowDoesNotDrill() {
    // 作成導線行で → を押しても潜らない（workspace 行でないため）。Enter は作成フォームのまま。
    let p = palette()
    var seed: String??
    p.onCreateFlow = { seed = $0 }
    p.setItems(items([("default", true)]))
    type(p, "infra")  // rows: 作成導線行のみ
    send(p, right)  // → は無視（潜らない）
    send(p, enter)  // 一覧のまま作成フォームへ
    XCTAssertEqual(seed, "infra", "作成導線行では → で潜らず Enter で作成フォームへ")
  }
}
