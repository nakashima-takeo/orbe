import AppKit
import XCTest

@testable import Orbe

/// ボードのウィジェットの並び——制御 API で置く・外すと、前面のボードがすぐ描き直り、焦点はボードの中にあるときだけ追う——を実窓で固定する。
///
/// 壊れると何が起きるか: 欄に焦点があるところでウィジェットを外すと焦点が窓へ落ち、⌘⇧] などの窓のキーまで黙って消える。端末や ⌘⇧X で
/// 作業中の人の焦点を、AI がウィジェットを置いた瞬間に依頼の欄が奪い、打鍵が欄へ流れる。ボードを持たない workspace にウィジェットが置け、
/// 外から見えない並びが保存に残る。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerBoardWidgetsTests: OrbeTestCase {
  private var shown: WindowController?

  override func setUp() {
    super.setUp()
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  override func tearDown() {
    shown?.window.orderOut(nil)
    shown = nil
    super.tearDown()
  }

  private static let nextTabKey = NSEvent.key("}", [.command, .shift])
  private static let prevTabKey = NSEvent.key("{", [.command, .shift])

  /// Home を前面にしてタブを `count` 枚開き、ボードを選んで、画面外に出した WindowController。焦点は依頼の欄。
  @MainActor private func homeOnBoard(tabs count: Int) throws -> WindowController {
    let wc = WindowController()
    shown = wc
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
    wc.switchWorkspace(to: try XCTUnwrap(wc.store.homeIndex))
    for _ in 0..<count { wc.newTab() }
    wc.statusModel.onSelectBoard()
    pump()
    return wc
  }

  private func widgets(_ result: Result<Any, ControlError>) -> [String]? {
    guard case .success(let value) = result else { return nil }
    return ((value as? [String: Any])?["widgets"] as? [[String: Any]])?.compactMap {
      $0["kind"] as? String
    }
  }

  private func type(_ wc: WindowController, _ character: String) throws {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
      context: nil, characters: character, charactersIgnoringModifiers: character,
      isARepeat: false, keyCode: 0)
    NSApp.sendEvent(try XCTUnwrap(event))
    pump()
  }

  private func pump() {
    let end = Date().addingTimeInterval(0.3)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  // MARK: - 焦点

  /// 欄に焦点があるところでウィジェットを外すと、ボードは空になり、焦点はボードの中（ホスト）に残って ⌘⇧] / ⌘⇧[ が効く。置き直すと
  /// 欄に焦点が入り、そのまま打てる。
  @MainActor func testRemovingTheWidgetKeepsTheFocusInTheBoardAndAddingItStartsAtTheField() throws {
    let wc = try homeOnBoard(tabs: 1)
    let homeId = wc.current.id
    XCTAssertTrue(wc.window.firstResponder is NSTextView, "前提: 焦点は依頼の欄")

    XCTAssertEqual(
      widgets(wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)), [])
    pump()
    XCTAssertEqual(wc.board.widgets, [], "ボードはすぐ空になる")
    XCTAssertTrue(wc.boardView.focusIsInside, "焦点は窓へ落ちずボードの中に残る")
    try type(wc, "a")
    XCTAssertTrue(wc.boardView.focusIsInside, "空のボードの打鍵は飲まれ、焦点は動かない")

    XCTAssertTrue(wc.window.performKeyEquivalent(with: Self.prevTabKey), "⌘⇧[ が効く")
    XCTAssertEqual(wc.current.selection, .tab(wc.current.tabs[0]), "ボードから巡回してタブへ")
    wc.statusModel.onSelectBoard()
    pump()
    XCTAssertTrue(wc.boardView.focusIsInside, "空のボードを選ぶと焦点はボードの中")
    XCTAssertTrue(wc.window.performKeyEquivalent(with: Self.nextTabKey), "⌘⇧] が効く")
    XCTAssertEqual(wc.current.selection, .tab(wc.current.tabs[0]))
    wc.statusModel.onSelectBoard()
    pump()

    XCTAssertEqual(
      widgets(wc.controlAddBoardWidget(workspaceId: homeId, widget: .automation)), ["automation"])
    pump()
    XCTAssertEqual(wc.board.automation.place, .request)
    XCTAssertTrue(wc.window.firstResponder is NSTextView, "置かれたウィジェットの欄に焦点が入る")
    try type(wc, "b")
    XCTAssertEqual(wc.board.automation.requestText, "b", "そのまま打てる")
  }

  /// 端末タブで作業中にウィジェットを外しても置いても、焦点と選択は動かない。
  @MainActor func testChangingTheWidgetsBehindATerminalTabLeavesTheFocusThere() throws {
    let wc = try homeOnBoard(tabs: 1)
    let homeId = wc.current.id
    let tab = wc.current.tabs[0]
    wc.select(.tab(tab))
    pump()
    let focused = wc.window.firstResponder

    _ = wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)
    pump()
    XCTAssertTrue(wc.window.firstResponder === focused, "外しても端末の焦点は動かない")
    _ = wc.controlAddBoardWidget(workspaceId: homeId, widget: .automation)
    pump()
    XCTAssertTrue(wc.window.firstResponder === focused, "置いても依頼の欄が焦点を奪わない")
    XCTAssertEqual(wc.current.selection, .tab(tab), "選択も動かない")
  }

  /// ボードの上に ⌘⇧X を開いている間にウィジェットを置いても外しても、打鍵は ⌘⇧X の入力欄に届いたまま。
  @MainActor func testChangingTheWidgetsUnderThePaletteLeavesTheFocusInThePalette() throws {
    let wc = try homeOnBoard(tabs: 0)
    let homeId = wc.current.id
    _ = wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)
    pump()
    wc.showTaskPalette()
    pump()
    let palette = try XCTUnwrap(wc.model.taskPalette)

    _ = wc.controlAddBoardWidget(workspaceId: homeId, widget: .automation)
    pump()
    try type(wc, "x")
    XCTAssertEqual(palette.query, "x", "置いても打鍵は ⌘⇧X に届く")
    XCTAssertEqual(wc.board.automation.requestText, "", "ボードの欄は焦点を奪わない")

    _ = wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)
    pump()
    try type(wc, "y")
    XCTAssertEqual(palette.query, "xy", "外しても打鍵は ⌘⇧X に届く")
  }

  /// Home が背景にある間に変えても、Home に戻ると変えた並びで出る。
  @MainActor func testChangingAnInactiveHomesWidgetsShowsWhenHomeReturns() throws {
    let wc = try homeOnBoard(tabs: 0)
    let homeIndex = try XCTUnwrap(wc.store.homeIndex)
    let homeId = wc.current.id
    let other = try XCTUnwrap(wc.workspaces.firstIndex { $0.name == "default" })
    wc.switchWorkspace(to: other)

    _ = wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)
    XCTAssertEqual(wc.activeWorkspace, other, "前面の workspace は動かない")
    wc.switchWorkspace(to: homeIndex)
    pump()
    XCTAssertEqual(wc.board.widgets, [], "戻ると空のボード")
    XCTAssertTrue(wc.boardView.focusIsInside, "焦点はボードの中")
  }

  // MARK: - 断り

  /// ボードを持たない workspace と知らない workspace は断られ、何も変わらない。既にあるものを置く・無いものを外すは何も変えずに
  /// 成功する。
  @MainActor func testRefusalsAndNoOps() throws {
    let wc = try homeOnBoard(tabs: 0)
    let homeId = wc.current.id
    let other = try XCTUnwrap(wc.workspaces.first { $0.name == "default" })

    for result in [
      wc.controlListBoardWidgets(workspaceId: other.id),
      wc.controlAddBoardWidget(workspaceId: other.id, widget: .automation),
      wc.controlRemoveBoardWidget(workspaceId: other.id, widget: .automation),
    ] {
      guard case .failure(let error) = result else { return XCTFail("ボードが無いのに成功した") }
      XCTAssertEqual(error.code, -32000)
    }
    XCTAssertNil(other.boardWidgets, "ボードを持たない workspace に並びを残さない")
    guard case .failure(let unknown) = wc.controlListBoardWidgets(workspaceId: UUID()) else {
      return XCTFail("知らない workspace で成功した")
    }
    XCTAssertEqual(unknown.code, -32004)

    XCTAssertEqual(
      widgets(wc.controlListBoardWidgets(workspaceId: homeId)), ["automation"], "決めていなければ既定")
    XCTAssertEqual(
      widgets(wc.controlAddBoardWidget(workspaceId: homeId, widget: .automation)), ["automation"])
    XCTAssertNil(wc.current.boardWidgets, "既にあるものを置いても何も変えない")
    XCTAssertEqual(
      widgets(wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)), [])
    XCTAssertEqual(
      widgets(wc.controlRemoveBoardWidget(workspaceId: homeId, widget: .automation)), [])

    let listed = wc.controlListWorkspaces()
    XCTAssertEqual(
      listed.filter { $0["hasBoard"] as? Bool == true }.compactMap { workspaceUUID($0["id"]) },
      [homeId],
      "hasBoard は Home だけ")
  }

  // MARK: - 保存

  /// 外した並びは再起動しても空のまま戻る。保存に重なった種類は 1 つに落ちる。
  @MainActor func testWidgetsSurviveARestart() throws {
    let wc = try homeOnBoard(tabs: 0)
    _ = wc.controlRemoveBoardWidget(workspaceId: wc.current.id, widget: .automation)
    wc.flushSave()

    let emptied = WindowController()
    let emptiedHome = emptied.workspaces[try XCTUnwrap(emptied.store.homeIndex)]
    XCTAssertEqual(
      widgets(emptied.controlListBoardWidgets(workspaceId: emptiedHome.id)), [], "空のまま戻る")

    var file = try XCTUnwrap(WorkspacePersistence.load())
    let homeIndex = try XCTUnwrap(
      file.workspaces.firstIndex { $0.id == file.homeWorkspaceId })
    file.workspaces[homeIndex].boardWidgets = [.automation, .automation]
    WorkspacePersistence.save(file)

    let restored = WindowController()
    let home = restored.workspaces[try XCTUnwrap(restored.store.homeIndex)]
    XCTAssertEqual(
      widgets(restored.controlListBoardWidgets(workspaceId: home.id)), ["automation"], "重なりは 1 つ")
  }
}
