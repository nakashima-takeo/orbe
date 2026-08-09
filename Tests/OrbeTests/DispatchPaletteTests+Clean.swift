import XCTest

@testable import Orbe

/// list / clean の 2 モードを持つカードの遷移契約。`DispatchCleanModel` の中身は
/// `DispatchCleanModelTests` が持ち、ここは**モードの出入りそのもの**だけを固定する。
@MainActor
extension DispatchPaletteTests {

  /// **`clean` 行はパレット内の画面遷移で、外の決定経路には出さない。**
  /// ここが崩れると `DispatchDataProvider.prepareDirectory` に `.clean` が届き、completion が
  /// 呼ばれず `isPreparing` が立ったままパレットが閉じられなくなる（release では assertion も消える）。
  func testCleanRowEntersCleanModeInsteadOfExecuting() throws {
    let p = makeModel()
    p.classification = DispatchWorktreeClassifier.classify([
      DispatchCleanFacts(
        path: "/wt/a", branch: "feat/a", head: "aaa", isGone: true, unmergedCommits: 0)
    ])
    var executed: [DispatchItem] = []
    p.onExecute = { executed.append($0) }

    p.activate(at: try XCTUnwrap(p.items.firstIndex { $0.action == .clean }))
    XCTAssertTrue(executed.isEmpty, "clean 行は onExecute に流さない")
    XCTAssertEqual(p.mode, .clean)
    XCTAssertEqual(p.clean.rows.map(\.name), ["a"], "分類スナップショットで開く")
  }

  /// 分類が未着地なら握り潰す（list に留まる）。
  func testCleanRowIsInertUntilClassificationLands() throws {
    let p = makeModel()
    var executed: [DispatchItem] = []
    p.onExecute = { executed.append($0) }

    p.activate(at: try XCTUnwrap(p.items.firstIndex { $0.action == .clean }))
    XCTAssertTrue(executed.isEmpty)
    XCTAssertEqual(p.mode, .list, "未着地では画面が変わらない")
  }

  /// esc で list へ戻ると、カーソルは入口の `clean` 行を指す。
  func testExitCleanReturnsCursorToCleanRow() {
    let p = makeModel()
    p.classification = []
    p.selected = 0
    p.enterClean()
    p.exitClean()
    XCTAssertEqual(p.mode, .list)
    XCTAssertEqual(p.selectedItem?.action, .clean)
  }
}
