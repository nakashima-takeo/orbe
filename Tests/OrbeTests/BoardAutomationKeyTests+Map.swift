import SwiftUI
import XCTest

@testable import Orbe

/// 一覧と地図の行き来と、地図のノードの段のキー。
extension BoardAutomationKeyTests {
  private func card(_ automation: BoardAutomationModel) -> BoardAutomationNodeValue? {
    let now = automation.runner.now()
    return automation.card(
      text: automation.text(LocalizationStore(language: .ja), now: now), now: now)
  }

  /// 一覧の ↵ は今すぐ実行せずに地図の先頭のノードへ入る。地図の esc は一覧の同じ行へ戻り、ノードの選択とカードが消える。
  func testEnterInTheListOpensTheMapWithoutRunningAndEscapeLeavesIt() throws {
    let automation = board(DesignSceneFixtures.boardMapSamples()).automation
    send(.downArrow, to: automation)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)

    send(.return, to: automation)
    XCTAssertEqual(automation.place, .map)
    XCTAssertEqual(automation.selectedNodeKey, "github", "初めて入ると先頭のノード")
    XCTAssertFalse(automation.runner.isRunning(id), "↵ は流さない")
    XCTAssertNotNil(card(automation))

    send(.escape, to: automation)
    XCTAssertEqual(automation.place, .list)
    XCTAssertEqual(automation.selectedAutomation?.id, id, "同じ行")
    XCTAssertNil(automation.selectedMapStop)
    XCTAssertNil(card(automation), "カードの中身が消える")
  }

  /// 地図のノードの段では ↵・→ は何もせず、⌘↵ がそのノードまでを流す（道の外の取得は起こさない）。流している途中の ⌘↵ は赤で
  /// 断る。
  func testInTheMapCommandEnterFlowsOnlyUpToTheSelectedNode() throws {
    let model = board(DesignSceneFixtures.boardMapSamples())
    let automation = model.automation
    send(.downArrow, to: automation)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    send(.rightArrow, to: automation)
    XCTAssertEqual(automation.selectedNodeKey, "github", "前提")

    send(.return, to: automation)
    send(.rightArrow, to: automation)
    XCTAssertEqual(automation.place, .map)
    XCTAssertEqual(automation.selectedNodeKey, "github", "↵・→ で段は動かない")
    XCTAssertFalse(automation.runner.isRunning(id), "↵・→ は流さない")

    send(.return, .command, to: automation)
    XCTAssertTrue(automation.runner.isRunning(id, "github"))
    XCTAssertFalse(automation.runner.isRunning(id, "slack"), "選んだノードの道の外の取得は起こさない")

    send(.return, .command, to: automation)
    XCTAssertEqual(model.refusal, .automationErrRunning)
  }

  /// 地図のノードの段の space はそのノードだけを止める ⇄ 再開し（押し続けても 1 回）、地図の行とカードの頭に「一時停止中」、
  /// 予定のノードのカードの「次回」に「一時停止中」が出る。フッターは選んだノードの印で名前が替わる。自動化は止めない。
  func testSpaceInTheMapPausesOnlyTheSelectedNode() throws {
    let automation = board(DesignSceneFixtures.boardMapSamples()).automation
    send(.downArrow, to: automation)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    send(.rightArrow, to: automation)
    XCTAssertEqual(automation.selectedNodeKey, "github", "前提")
    let l10n = LocalizationStore(language: .ja)
    let now = automation.runner.now()
    func mapNode() throws -> BoardMapNode? {
      let detail = try XCTUnwrap(
        automation.detail(id, text: automation.text(l10n, now: now), now: now))
      return detail.rows.compactMap { row -> BoardMapNode? in
        guard case .node(let node) = row.content else { return nil }
        return node
      }.first { $0.id == automation.store.nodeId(id, "github") }
    }
    let pause = BoardAutomationHand.Operation.toggleNodePause
    XCTAssertTrue(automation.hints.contains(BoardKeyHint(pause.key, .automationPause)))

    send(.space, to: automation)
    send(.space, repeating: true, to: automation)
    let github = try XCTUnwrap(automation.store.automation(id)).state(key: "github")
    XCTAssertTrue(github.paused, "押し続けても 1 回だけ")
    XCTAssertEqual(automation.store.automation(id)?.paused, false, "自動化は止めない")
    XCTAssertEqual(try mapNode()?.look, .paused)
    let paused = try XCTUnwrap(card(automation))
    XCTAssertEqual(paused.state, .paused)
    XCTAssertEqual(
      paused.facts.first { $0.label == .boardNodeNext }?.value.map(\.text), ["一時停止中"])
    XCTAssertTrue(automation.hints.contains(BoardKeyHint(pause.key, .automationResume)))

    send(.space, to: automation)
    XCTAssertEqual(automation.store.automation(id)?.state(key: "github").paused, false)
    XCTAssertEqual(try mapNode()?.look, .idle)
  }

  // MARK: - 通知

  /// 一覧の先頭の行から地図へ入り、「通知」の段で → を押して開く。
  private func openNotify(_ automation: BoardAutomationModel) {
    send(.downArrow, to: automation)
    send(.rightArrow, to: automation)
    send(.upArrow, to: automation)
    send(.rightArrow, to: automation)
  }

  private func notifyLine(_ automation: BoardAutomationModel, _ id: Int) -> String? {
    let text = automation.text(LocalizationStore(language: .ja), now: automation.runner.now())
    return automation.detail(id, text: text, now: automation.runner.now())?.notify
  }

  /// 「通知」の段の → で開くと今の設定（通知しない）の行から。↓ ↵ でその自動化の通知だけがメニューバーに替わり、見出しが
  /// 追従して閉じる。↵ でも開き、開き直すと印の行から始まり、↑ は端で巡回する。
  func testTheNotifyRowOpensAtTheCurrentSettingAndReturnChoosesIt() throws {
    let automation = board().automation
    openNotify(automation)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    let before = try XCTUnwrap(automation.store.automation(id)).definition
    XCTAssertNil(before.notify, "前提: 見本は通知しない")

    XCTAssertEqual(automation.notifyCursor, 0)
    XCTAssertEqual(automation.hints.map(\.key), ["↑↓", "↵", "←"])
    send(.downArrow, to: automation)
    send(.return, to: automation)

    var expected = before
    expected.notify = .menuBar
    XCTAssertEqual(automation.store.automation(id)?.definition, expected, "通知だけが替わる")
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(notifyLine(automation, id), "通知：メニューバー")
    XCTAssertEqual(automation.selectedMapStop, .notify, "段は動かない")
    XCTAssertTrue(
      automation.store.automations.filter { $0.id != id }.allSatisfy {
        $0.definition.notify == nil
      },
      "ほかの自動化は替わらない")

    send(.return, to: automation)
    XCTAssertEqual(automation.notifyCursor, 1, "印の行から")
    send(.upArrow, to: automation)
    send(.upArrow, to: automation)
    XCTAssertEqual(automation.notifyCursor, 2, "端で巡回する")
  }

  /// ← と esc は何も変えずに閉じ、「通知」の段に戻る。ノードの段の → は開かない。
  func testLeftAndEscapeCloseWithoutChanging() {
    let automation = board().automation
    openNotify(automation)

    send(.downArrow, to: automation)
    send(.leftArrow, to: automation)
    XCTAssertNil(automation.notifyCursor)
    send(.rightArrow, to: automation)
    send(.downArrow, to: automation)
    send(.escape, to: automation)
    XCTAssertNil(automation.notifyCursor)

    XCTAssertEqual(automation.store.automations, untouched)
    XCTAssertEqual(automation.selectedMapStop, .notify, "閉じると「通知」の段")
    send(.downArrow, to: automation)
    send(.rightArrow, to: automation)
    XCTAssertNil(automation.notifyCursor, "ノードの段の → は開かない")
  }

  /// 開いている間は、下のキー（space・↵ のリピート・⌘⌫・⌘↵・↑↓）は地図にも一覧にも効かない。
  func testKeysWhileOpenDoNotReachBelow() {
    let automation = board().automation
    openNotify(automation)
    let selected = automation.selectedAutomation?.id

    send(.space, to: automation)
    send(.return, repeating: true, to: automation)
    send(.backspace, .command, to: automation)
    send(.return, .command, to: automation)
    send(.downArrow, to: automation)

    XCTAssertEqual(automation.notifyCursor, 1, "↓ はメニューの中を動き、ほかのキーは握られる")
    XCTAssertEqual(automation.selectedAutomation?.id, selected)
    XCTAssertEqual(automation.selectedMapStop, .notify)
    XCTAssertEqual(automation.store.automations, untouched, "どれも変わらない")
    XCTAssertFalse(automation.store.automations.contains { automation.runner.isRunning($0.id) })
  }

  /// 通知だけを替えても、走っている回は止まらない。
  func testChoosingWhileRunningKeepsTheRun() throws {
    let automation = board().automation
    send(.downArrow, to: automation)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    send(.return, .command, to: automation)
    XCTAssertTrue(automation.runner.isRunning(id), "前提: 走っている")

    send(.rightArrow, to: automation)
    send(.upArrow, to: automation)
    send(.rightArrow, to: automation)
    send(.upArrow, to: automation)
    send(.return, to: automation)

    XCTAssertEqual(automation.store.automation(id)?.definition.notify, .notificationCenter)
    XCTAssertTrue(automation.runner.isRunning(id))
  }
}
