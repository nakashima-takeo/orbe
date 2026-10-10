import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 連（`TabGroup`）がエディターと面の配置を共有する配線を、実 `WindowController` で通す——連の中の切替は端末の入れ替え
/// だけ、別の連へは器ごと、休眠タブは器の mount で起きない、cd の 3 通り（タブだけ移る・連ごと付け替える・文書を移して
/// 畳む）と焦点、閉じたタブの端末の後片付け。
///
/// 壊れると何が起きるか。同じ worktree のタブを切り替えるたびにエディターが閉じたり開いたりし、配置と文書が消える。切り替えた
/// 瞬間に端末が描き直される。連の器を出しただけで休眠の agent が素のシェルとして起き、resume されない。cd したタブが元の
/// 連の文書を持ち去る、あるいは連の最後のタブの cd で文書が消える。端末で cd したのにエディター全面の連へ移って入力が
/// 見えない面へ届く。閉じたタブの surface が器に残り続ける。
extension WindowControllerTabGroupTests {
  private func layout(_ wc: WindowController) {
    wc.window.contentView?.layoutSubtreeIfNeeded()
  }

  private func directory(_ name: String) throws -> URL {
    let url = TestScratch.caseDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  /// 連の中の切替は器の中の端末の入れ替えだけ——器もエディターも配置も動かず、見える端末だけが替わる。切り替えた先の
  /// 端末は既に面の寸法を持っている（切替で resize が起きない）。焦点の面は連の記憶のまま。
  func testSwitchingWithinTheGroupOnlySwapsTheTerminal() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1"], activeTab: 0)
    let (a, b) = (wc.current.tabs[0], wc.current.tabs[1])
    let group = a.group
    XCTAssertTrue(b.group === group, "前提: 同じ連")
    group.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    layout(wc)
    pumpMain(until: { b.activated }, "隠れた兄弟が起きる")
    let size = a.surface.bounds.size
    XCTAssertGreaterThan(size.width, 0, "前提: 端末が実寸を持つ")
    XCTAssertEqual(b.surface.bounds.size, size, "隠れた兄弟も面の確定寸法を持つ")
    let mounted = wc.model.content.subviews

    wc.select(1)

    XCTAssertTrue(wc.model.content.subviews.elementsEqual(mounted, by: ===), "器は付け替わらない")
    XCTAssertTrue(group.view.shownTerminal === b.terminal)
    XCTAssertFalse(b.terminal.isHiddenOrHasHiddenAncestor)
    XCTAssertTrue(a.terminal.isHidden)
    XCTAssertEqual(group.faces, FaceLayout(editorRatio: 0.5, focus: .terminal), "配置は動かない")
    XCTAssertEqual(b.surface.bounds.size, size, "切替で寸法は変わらない")
    XCTAssertTrue(wc.window.firstResponder === b.surface, "連の焦点の面（端末）の、そのタブの端末へ")
  }

  /// 別の連のタブへ移ると器ごと入れ替わり、その連の配置になる。戻れば元の連の器と配置が残っている。
  func testSwitchingToAnotherGroupSwapsTheWholeView() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g2"], activeTab: 0)
    let (a, b) = (wc.current.tabs[0], wc.current.tabs[1])
    a.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)

    wc.select(1)
    XCTAssertTrue(a.group.view.isHidden)
    XCTAssertFalse(b.group.view.isHidden)
    XCTAssertEqual(b.group.faces, .terminalOnly, "新しい連は端末だけで始まる")
    XCTAssertTrue(wc.window.firstResponder === b.surface)

    wc.select(0)
    XCTAssertFalse(a.group.view.isHidden)
    XCTAssertTrue(b.group.view.isHidden)
    XCTAssertEqual(a.group.faces, FaceLayout(editorRatio: 1, focus: .editor))
    XCTAssertTrue(wc.window.firstResponder === a.group.view.editor)
  }

  /// 連の器が画面に出ても、同じ連の休眠タブは起きない——器に入るのは materialize 済みの端末だけで、休眠の兄弟は後続 tick に
  /// 1 枚ずつ起きてから差さる。
  func testMountingTheGroupViewDoesNotWakeDormantSiblings() throws {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [
            TabState(cwd: "/tmp/g1", agent: nil, explicitTitle: nil),
            TabState(
              cwd: "/tmp/g1", agent: AgentSession(command: "claude", sessionId: "s-1"),
              explicitTitle: nil),
          ])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let (a, dormant) = (wc.current.tabs[0], wc.current.tabs[1])

    XCTAssertTrue(a.group.view.superview === wc.model.content, "前提: 連の器が載っている")
    XCTAssertFalse(dormant.activated, "器の mount では起きない")
    XCTAssertTrue(a.group.view.terminals.elementsEqual([a.terminal], by: ===))
    XCTAssertNil(dormant.surface.surfacePtr, "surface も生まれていない")

    pumpMain(until: { dormant.activated }, "後続 tick で起きる")
    XCTAssertTrue(a.group.view.terminals.contains { $0 === dormant.terminal }, "起きてから器へ差さる")
  }

  /// cd で連を出たタブは、元の連に他のタブが残っていればそのタブだけが行き先の連（無ければ新しい連）へ移る。元の連の
  /// エディターと器はそのまま残る。
  func testCdLeavingSiblingsMovesOnlyTheTab() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1", "/tmp/g2"], activeTab: 0)
    let (a, b, c) = (wc.current.tabs[0], wc.current.tabs[1], wc.current.tabs[2])
    let old = a.group

    a.surface.currentPwd = "/tmp/g2"

    XCTAssertTrue(a.group === c.group, "行き先の連へ")
    XCTAssertTrue(b.group === old, "元の連は残る")
    XCTAssertFalse(old.view.terminals.contains { $0 === a.terminal }, "端末は元の器から外れる")
    XCTAssertTrue(c.group.view.shownTerminal === a.terminal, "行き先の器で見える")

    a.surface.currentPwd = "/tmp/g3"

    XCTAssertFalse(a.group === c.group, "行き先が無ければ新しい連")
    XCTAssertEqual(a.groupKey, GitWorktreeRoot.root(of: "/tmp/g3"))
    XCTAssertTrue(c.group.view.terminals.allSatisfy { $0 !== a.terminal })
  }

  /// 連の最後のタブが行き先の無い根へ cd すると、連ごとキーとエディター面の根が付け替わる。
  func testCdOfTheLastTabWithoutADestinationRekeysTheGroup() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g2"], activeTab: 0)
    let a = wc.current.tabs[0]
    let group = a.group

    a.surface.currentPwd = "/tmp/g3"

    XCTAssertTrue(a.group === group, "連はそのまま")
    XCTAssertEqual(group.key, GitWorktreeRoot.root(of: "/tmp/g3"))
    let root = MainActor.assumeIsolated { group.view.editor.tree.root }
    XCTAssertEqual(root, group.key, "エディター面の根も付け替わる")
  }

  /// 連の最後のタブが既にある連の根へ cd すると、元の文書は行き先の列の末尾へ移り（行き先の焦点は保つ）、元の連は畳まれて
  /// 器も外れる。
  func testCdOfTheLastTabIntoAnExistingGroupMovesTheDocuments() throws {
    let one = try directory("one")
    let two = try directory("two")
    let a = one.appendingPathComponent("a.txt")
    let b = two.appendingPathComponent("b.txt")
    try Data("a".utf8).write(to: a)
    try Data("b".utf8).write(to: b)
    let wc = try restore([one.path, two.path], activeTab: 0)
    let (first, second) = (wc.current.tabs[0], wc.current.tabs[1])
    try first.group.openFile(a)
    try second.group.openFile(b)
    let old = first.group

    first.surface.currentPwd = two.path

    XCTAssertTrue(first.group === second.group)
    let (documents, active) = MainActor.assumeIsolated {
      (second.group.editor.documents.map(\.url), second.group.editor.activeDocument?.url)
    }
    XCTAssertEqual(documents, [b, a], "元の文書は末尾へ")
    XCTAssertEqual(active, b, "行き先の焦点を保つ")
    XCTAssertTrue(MainActor.assumeIsolated { old.editor.documents.isEmpty })
    XCTAssertFalse(wc.model.content.subviews.contains { $0 === old.view }, "畳まれた連の器は外れる")
  }

  /// 前面のアクティブなタブが端末に焦点を置いたままエディター全面の連へ cd すると、その連は端末だけの配置になり、焦点は
  /// 端末に残る。
  func testCdWithTheTerminalFocusedIntoAnEditorOnlyGroupKeepsTheTerminal() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1", "/tmp/g2"], activeTab: 0)
    let (a, c) = (wc.current.tabs[0], wc.current.tabs[2])
    c.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    XCTAssertTrue(wc.window.firstResponder === a.surface, "前提: 端末に焦点")

    a.surface.currentPwd = "/tmp/g2"

    XCTAssertTrue(a.group === c.group)
    XCTAssertEqual(c.group.faces, .terminalOnly, "エディター全面の連は端末だけになる")
    XCTAssertTrue(wc.window.firstResponder === a.surface, "焦点は端末に残る")
  }

  /// 閉じたタブの端末は器から外れる（器に残ると surface がリークする）。連の器は残りのタブの端末を見せる。
  func testClosingATabRemovesItsTerminalFromTheGroupView() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1"], activeTab: 0)
    let (a, b) = (wc.current.tabs[0], wc.current.tabs[1])
    pumpMain(until: { b.activated }, "隠れた兄弟が起きる")

    wc.closeTab(a, origin: .process)
    pumpMain(until: { wc.current.tabs.count == 1 }, "閉じる")

    XCTAssertTrue(b.group.view.terminals.elementsEqual([b.terminal], by: ===))
    XCTAssertTrue(b.group.view.shownTerminal === b.terminal)
  }
}
