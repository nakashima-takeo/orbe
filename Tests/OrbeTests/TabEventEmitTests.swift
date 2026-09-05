import XCTest

@testable import Orbe

/// エージェント状態以外の制御イベント——`title` / `pwd` / `tab_closed`——をタブが流す契約を固定する。
/// surface が報告する事実（タイトル・cwd）は値の実変化でだけ流れ、`tab_closed` はタブの消滅で流れる。
/// `agent_state` の同じ契約は `AgentStateEmitTests` が持つ。
///
/// 壊れると、`orb wait --kind title|pwd` が同値の再報告で起きる（シェルは同じ cwd を何度も報告する）か、
/// タブが消えても `tab_closed` が流れず `orb wait` / `prompt_agent` がタイムアウトまで待つ。
/// 既存の `ControlWireTests+WaitForEvent` は `emit` を直叩きするので、surface の変化がタブを経て
/// wire に出ることはここでしか測られない。
///
/// `TerminalTab` は window 未接続なら libghostty surface を生成しないため、純ロジックとして駆動できる。
/// 「流れない」は barrier で決定論的に示す。
final class TabEventEmitTests: OrbeTestCase {
  private var wire: ControlWire?

  override func tearDown() {
    wire?.teardown()
    wire = nil
    super.tearDown()
  }

  /// 指定 kind の待機をタブに絞って張り、登録完了を barrier で確定させる。
  private func armWait(id: Int, kind: String, tabId: Int) -> ControlWire {
    let w = wire ?? ControlWire(target: nil)
    wire = w
    w.send([
      "jsonrpc": "2.0", "id": id, "method": "wait_for_event",
      "params": ["kinds": [kind], "tabId": tabId],
    ])
    w.barrier()
    return w
  }

  private func event(_ response: [String: Any]?) -> [String: Any]? {
    (response?["result"] as? [String: Any])?["event"] as? [String: Any]
  }

  // MARK: - title / pwd（実変化でだけ流れる）

  /// surface のタイトル変化は `title` に新値を載せて流れ、同値の再代入では流れない。
  func testTitleChangeEmitsTitleOnlyOnRealChange() throws {
    let tab = TerminalTab(cwd: "/tmp")
    let w = armWait(id: 1, kind: "title", tabId: tab.id)

    tab.surface.title = "vim"

    let first = try XCTUnwrap(event(w.nextResponse()))
    XCTAssertEqual(first["kind"] as? String, "title")
    XCTAssertEqual(first["tabId"] as? Int, tab.id)
    XCTAssertEqual(first["value"] as? String, "vim")

    _ = armWait(id: 2, kind: "title", tabId: tab.id)
    tab.surface.title = "vim"
    w.barrier()  // barrier が先に返る＝同値の再代入はイベントを出していない

    tab.surface.title = "zsh"
    XCTAssertEqual(event(w.nextResponse())?["value"] as? String, "zsh", "実変化では張った待機が起きる")
  }

  /// OSC 7 の cwd 報告は `pwd` に新値を載せて流れ、同じ cwd の再報告では流れない。
  func testPwdChangeEmitsPwdOnlyOnRealChange() throws {
    let tab = TerminalTab(cwd: "/tmp")
    let w = armWait(id: 1, kind: "pwd", tabId: tab.id)

    tab.surface.currentPwd = "/work"

    let first = try XCTUnwrap(event(w.nextResponse()))
    XCTAssertEqual(first["kind"] as? String, "pwd")
    XCTAssertEqual(first["tabId"] as? Int, tab.id)
    XCTAssertEqual(first["value"] as? String, "/work")

    _ = armWait(id: 2, kind: "pwd", tabId: tab.id)
    tab.surface.currentPwd = "/work"
    w.barrier()

    tab.surface.currentPwd = "/work/api"
    XCTAssertEqual(
      event(w.nextResponse())?["value"] as? String, "/work/api", "実変化では張った待機が起きる")
  }

  // MARK: - tab_closed（消滅で流れる）

  /// タブが消滅すると `tab_closed` がそのタブの id で流れる。
  func testTabDeallocationEmitsTabClosed() throws {
    var tab: TerminalTab? = TerminalTab(cwd: "/tmp")
    let id = try XCTUnwrap(tab?.id)
    let w = armWait(id: 1, kind: "tab_closed", tabId: id)

    tab = nil

    let closed = try XCTUnwrap(event(w.nextResponse()))
    XCTAssertEqual(closed["kind"] as? String, "tab_closed")
    XCTAssertEqual(closed["tabId"] as? Int, id)
  }
}
