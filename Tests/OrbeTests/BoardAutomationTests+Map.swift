import AppKit
import XCTest

@testable import Orbe

/// 一覧と地図の行き来と、地図のノードの段のキー。見本の地図（12 ノードの「受け持ちの全部」ほか）を実窓に載せ、実 `NSEvent` の
/// キーを届ける。
///
/// 壊れると何が起きるか: ノードを見るつもりの ↵ で自動化が丸ごと流れ、副作用や報告が走る。地図から一覧へ戻れないか、戻っても
/// 前のノードが選ばれたままカードに残り、一覧で効くはずのキーがノードに効く。「ここまで今すぐ実行」で選んだノードの先まで流れるか、
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
}
