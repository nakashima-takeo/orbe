import AppKit
import XCTest

@testable import Orbe

/// 一覧と地図の行き来と、地図のノードの段のキー。見本の地図（12 ノードの「受け持ちの全部」ほか）を実窓に載せ、実 `NSEvent` の
/// キーを届ける。
///
/// 壊れると何が起きるか: ノードを見るつもりの ↵ で自動化が丸ごと流れ、副作用や報告が走る。地図から一覧へ戻れないか、戻っても
/// 前のノードが選ばれたままカードに残り、一覧で効くはずのキーがノードに効く。「選んだノードまで実行」で選んだノードの先まで流れるか、
/// 関係の無い取得まで起きる。
extension BoardAutomationTests {
  private func card(_ automation: BoardAutomationModel) -> BoardAutomationNodeValue? {
    let now = automation.runner.now()
    return automation.card(
      text: automation.text(LocalizationStore(language: .ja), now: now), now: now)
  }

  /// 一覧の ↵ は今すぐ実行せずに地図の先頭のノードへ入る。地図の esc は一覧の同じ行へ戻り、ノードの選択とカードが消える。
  func testEnterInTheListOpensTheMapWithoutRunningAndEscapeLeavesIt() throws {
    let model = board(DesignSceneFixtures.boardMapSamples())
    let automation = model.automation
    let window = mount(model)
    down(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)

    send(Key.enter, "\r", to: window)
    XCTAssertEqual(automation.place, .map)
    XCTAssertEqual(automation.selectedNodeKey, "github", "初めて入ると先頭のノード")
    XCTAssertFalse(automation.runner.isRunning(id), "↵ は流さない")
    XCTAssertNotNil(card(automation))

    send(Key.escape, "\u{1B}", to: window)
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
    let window = mount(model)
    down(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    right(window)
    XCTAssertEqual(automation.selectedNodeKey, "github", "前提")

    send(Key.enter, "\r", to: window)
    right(window)
    XCTAssertEqual(automation.place, .map)
    XCTAssertEqual(automation.selectedNodeKey, "github", "↵・→ で段は動かない")
    XCTAssertFalse(automation.runner.isRunning(id), "↵・→ は流さない")

    send(Key.enter, "\r", .command, to: window)
    XCTAssertTrue(automation.runner.isRunning(id, "github"))
    XCTAssertFalse(automation.runner.isRunning(id, "slack"), "選んだノードの道の外の取得は起こさない")

    send(Key.enter, "\r", .command, to: window)
    XCTAssertEqual(model.refusal, .automationErrRunning)
  }

  /// 地図のノードの段の space はそのノードだけを止める ⇄ 再開し（押し続けても 1 回）、地図の行とカードの頭に「一時停止中」、
  /// 予定のノードのカードの「次回」に「一時停止中」が出る。フッターは選んだノードの印で名前が替わる。自動化は止めない。
  func testSpaceInTheMapPausesOnlyTheSelectedNode() throws {
    let model = board(DesignSceneFixtures.boardMapSamples())
    let automation = model.automation
    let window = mount(model)
    down(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    right(window)
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

    send(Key.space, " ", to: window)
    send(Key.space, " ", repeating: true, to: window)
    let github = try XCTUnwrap(automation.store.automation(id)).state(key: "github")
    XCTAssertTrue(github.paused, "押し続けても 1 回だけ")
    XCTAssertEqual(automation.store.automation(id)?.paused, false, "自動化は止めない")
    XCTAssertEqual(try mapNode()?.paused, true)
    let paused = try XCTUnwrap(card(automation))
    XCTAssertTrue(paused.paused)
    XCTAssertEqual(
      paused.facts.first { $0.label == .boardNodeNext }?.value.map(\.text), ["一時停止中"])
    XCTAssertTrue(automation.hints.contains(BoardKeyHint(pause.key, .automationResume)))

    send(Key.space, " ", to: window)
    XCTAssertEqual(automation.store.automation(id)?.state(key: "github").paused, false)
    XCTAssertEqual(try mapNode()?.paused, false)
  }
}
