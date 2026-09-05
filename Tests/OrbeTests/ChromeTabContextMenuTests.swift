import AppKit
import XCTest

@testable import Orbe

/// タブ行のコンテキストメニュー「エージェント状態をリセット」の配線
/// （`StatusRowModel.onResetAgentState` → `WindowController` → `TerminalTab.resetAgentState`）。
///
/// 宛先はタブの同一性（`TerminalTab.id`）で解決する。メニューは開いたまま任意時間止まり、
/// その間に背景タブが消えると位置 index は別タブを指す——そこが崩れると、右クリックしたのとは
/// 別のタブの通知が黙って消える（ユーザーからは「効かなかった」としか見えない）。
///
/// `.contextMenu` のポップアップそのもの（項目の有無・グレーアウト描画・ラベル）は AppKit の
/// 別ウィンドウで in-process から開けないため、ここが測るのは項目を選んだ結果だけ。
/// 無効条件と同じ集合であること（グリフが出る ⇔ リセットできる）は `TerminalTabTests` が持つ。
final class ChromeTabContextMenuTests: OrbeTestCase {

  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  private func tab(_ wc: WindowController, at i: Int) -> TerminalTab { wc.current.tabs[i] }

  // MARK: - 宛先の解決

  /// 非選択タブのリセットは、選択切替を挟まずそのタブだけを idle へ落とす。
  func testResetsOnlyTheTargetTabWithoutSwitchingSelection() throws {
    let wc = WindowController()
    wc.newTab()
    XCTAssertEqual(wc.current.tabs.count, 2, "前提: タブ 2 枚で末尾がアクティブ")
    let target = tab(wc, at: 0)
    let other = tab(wc, at: 1)
    setReportedState(target, "waiting")
    setReportedState(other, "working")
    let active = wc.current.tabs[wc.current.active]

    wc.statusModel.onResetAgentState(wc.current.tabs[0].id)

    XCTAssertEqual(target.agentState, "idle", "指されたタブは idle へ")
    XCTAssertEqual(other.agentState, "working", "他のタブは変わらない")
    XCTAssertTrue(wc.current.tabs[wc.current.active] === active, "アクティブタブは切り替わらない")
  }

  /// メニューを開いている間に前のタブが消えて位置が詰まっても、指したタブに効く。
  func testResolvesTargetTabByIdentityAfterTabsShift() throws {
    let wc = WindowController()
    wc.newTab()
    wc.newTab()
    XCTAssertEqual(wc.current.tabs.count, 3, "前提: タブ 3 枚")
    let target = tab(wc, at: 1)
    let neighbor = tab(wc, at: 2)
    setReportedState(target, "waiting")
    setReportedState(neighbor, "waiting")
    let targetId = wc.current.tabs[1].id

    wc.closeTab(wc.current.tabs[0], origin: .gesture)  // 宛先タブが index 1 → 0 へ詰まる

    wc.statusModel.onResetAgentState(targetId)

    XCTAssertEqual(target.agentState, "idle", "位置がずれても指したタブに効く")
    XCTAssertEqual(neighbor.agentState, "waiting", "詰まった先に居るタブを巻き込まない")
  }

  /// メニューを開いている間に対象タブ自体が消えたら何も起きない（落ちない）。
  func testUnknownTabIdChangesNothing() throws {
    let wc = WindowController()
    wc.newTab()
    let closedId = wc.current.tabs[0].id
    let survivor = tab(wc, at: 1)
    setReportedState(survivor, "waiting")
    wc.closeTab(wc.current.tabs[0], origin: .gesture)

    wc.statusModel.onResetAgentState(closedId)

    XCTAssertEqual(wc.current.tabs.count, 1, "タブ集合は変わらない")
    XCTAssertEqual(survivor.agentState, "waiting", "残ったタブを巻き込まない")
  }

  // MARK: - リセット後の再投影

  /// リセットは chrome の再投影を自分で要求する。`flushChrome` は dirty が立っていなければ
  /// 何もしないので、配線が `refreshChrome` を鳴らしていなければここが落ちる。
  func testResetReprojectsTabGlyphRollupAndAttentionRows() throws {
    let wc = WindowController()
    let tab = tab(wc, at: 0)
    setReportedState(tab, "waiting", message: AgentMessage(text: "approve?", source: "tool"))
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.glyphs.first, .waiting, "前提: タブに waiting グリフが出ている")
    XCTAssertEqual(wc.attentionStore.rows.map(\.state), ["waiting"], "前提: Attention 一覧に載っている")

    wc.statusModel.onResetAgentState(wc.current.tabs[0].id)
    wc.flushChrome()

    XCTAssertNil(wc.statusModel.glyphs.first ?? nil, "タブグリフが消える")
    XCTAssertEqual(wc.statusModel.rollup.map(\.state), ["idle"], "横断ストリップは休止へ移る")
    XCTAssertTrue(wc.attentionStore.rows.isEmpty, "Attention 一覧から消える")
  }

  // MARK: - 宛先を指せる土台

  /// `tabIds` はタブ行と同じ順・同じ長さで並ぶ（`stateGlyph(i)` と `tabId(i)` が同じタブを指す）。
  func testTabIdsMirrorTheTabRowInOrder() {
    let wc = WindowController()
    wc.newTab()
    wc.newTab()
    wc.flushChrome()

    XCTAssertEqual(wc.statusModel.tabIds, wc.current.tabs.map(\.id), "タブ行と同じ順")
    XCTAssertEqual(wc.statusModel.tabIds.count, wc.statusModel.titles.count, "titles と同じ長さ")
    XCTAssertEqual(wc.statusModel.tabIds.count, wc.statusModel.glyphs.count, "glyphs と同じ長さ")
  }
}
