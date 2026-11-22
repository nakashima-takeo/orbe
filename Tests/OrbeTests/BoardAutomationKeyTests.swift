import SwiftUI
import XCTest

@testable import Orbe

/// ボードの自動化のウィジェットのキーの入口（欄の `handleRequestKey`・一覧の `handleKey`・地図の `handleMapKey`）に、キー 1 打の
/// 値を直接渡して、選んだ自動化・ノードへのキーと、欄と一覧の行き来と、そのキーを握ることを固定する。走らせ役は取得が終わらない
/// 偽物で、本物の claude は起きない。
///
/// 壊れると何が起きるか: ⌘⌫ を押し続けたリピートで次の自動化まで消える（戻せない）。space のリピートで止める ⇄ 再開が往復し、
/// どちらになったか分からない。⇧↵ で今すぐ実行が走る。ノードを見るつもりの ↵ で自動化が丸ごと流れ、副作用や報告が走る。
/// 「選んだノードまで実行」で選んだノードの先まで流れる。通知を替えたつもりが替わらない・別の自動化が替わる・替えた拍子に
/// 走っている回が止まる。通知のサブメニューを開いている間のキーが下の地図や一覧へ抜けて、止める・実行・削除が起きる。
@MainActor
final class BoardAutomationKeyTests: OrbeTestCase {
  // 見本『Home』の 4 件（DesignSceneFixtures+Board）。
  static let slack = 1
  static let github = 2
  static let failingBacklog = 3
  static let pausedGmail = 4

  /// ボードを選んだときと同じ焦点の当て直し（`focus()`）で中へ入ったボード。ウィジェットは欄から始まる。`samples` を省くと見本の 4 件。
  func board(_ samples: [AutomationSample]? = nil) -> BoardModel {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(
          samples ?? DesignSceneFixtures.boardAutomationSamples())),
      widgets: [.automation])
    model.focus()
    return model
  }

  /// 見本の 4 件を置いたままの自動化（置き方は決定論なので、別の DB に置いても同じ値になる）。
  var untouched: [Automation] {
    DesignSceneFixtures.automationStore(DesignSceneFixtures.boardAutomationSamples()).automations
  }

  /// キー 1 打を、焦点の場所（`place`）の入口へ渡し、握る（入力欄へ届けない・焦点をボードの外へ逃がさない）ことを確かめる。
  /// 場所と入口の対応はビューの配線と同じ。
  func send(
    _ key: KeyEquivalent, _ modifiers: EventModifiers = [], repeating: Bool = false,
    to automation: BoardAutomationModel, file: StaticString = #filePath, line: UInt = #line
  ) {
    let input = KeyInput(key, modifiers: modifiers, isRepeat: repeating)
    let result =
      switch automation.place {
      case .request: automation.handleRequestKey(input)
      case .list: automation.handleKey(input)
      case .map: automation.handleMapKey(input)
      }
    XCTAssertEqual(result, .handled, "握る（入力欄へ届けない）", file: file, line: line)
  }

  // MARK: - 一覧

  /// ↓ で選び、space で止める ⇄ 再開（沈んでも選択は付いていく）、⌘↵ で今すぐ実行、⌘⌫ で消して同じ位置の行を選ぶ。
  func testKeysActOnTheSelectedAutomation() {
    let model = board()
    let automation = model.automation

    send(.downArrow, to: automation)
    send(.downArrow, to: automation)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.slack)

    send(.space, to: automation)
    XCTAssertEqual(automation.store.automation(Self.slack)?.paused, true)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.slack, "末尾へ沈んでも選択は同じ自動化")
    send(.space, to: automation)
    XCTAssertEqual(automation.store.automation(Self.slack)?.paused, false)

    send(.return, .command, to: automation)
    XCTAssertTrue(automation.runner.isRunning(Self.slack))
    send(.return, .command, to: automation)
    XCTAssertEqual(model.refusal, .automationErrRunning, "走っている間の ⌘↵ は赤で断る")

    send(.downArrow, to: automation)
    XCTAssertNil(model.refusal, "↓ で消える")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.github, "前提")
    send(.backspace, .command, to: automation)
    XCTAssertNil(automation.store.automation(Self.github))
    XCTAssertEqual(automation.selectedAutomation?.id, Self.pausedGmail, "同じ位置の行")
  }

  /// space・⌘↵・⌘⌫ は押し続けても 1 回だけ効く。
  func testHeldKeysActOnce() {
    let model = board()
    let automation = model.automation
    send(.downArrow, to: automation)
    send(.downArrow, to: automation)

    send(.space, to: automation)
    send(.space, repeating: true, to: automation)
    XCTAssertEqual(automation.store.automation(Self.slack)?.paused, true, "止める ⇄ 再開は 1 回だけ（往復しない）")

    send(.return, .command, to: automation)
    send(.return, .command, repeating: true, to: automation)
    XCTAssertTrue(automation.runner.isRunning(Self.slack))
    XCTAssertNil(model.refusal, "リピートで「実行中のため、今は実行できません」の赤を出さない")

    send(.backspace, .command, to: automation)
    send(.backspace, .command, repeating: true, to: automation)
    send(.backspace, .command, repeating: true, to: automation)
    XCTAssertEqual(
      automation.store.automations.map(\.id), [Self.github, Self.failingBacklog, Self.pausedGmail],
      "消えるのは 1 件だけ")
  }

  /// 今すぐ実行は ⌘↵ だけ。⇧↵・文字キーは何も起こさない。
  func testModifiedEnterAndLettersDoNothing() {
    let model = board()
    let automation = model.automation
    send(.downArrow, to: automation)

    send(.return, .shift, to: automation)
    send("x", to: automation)

    XCTAssertFalse(
      automation.store.automations.contains { automation.runner.isRunning($0.id) }, "どれも走らない")
    XCTAssertEqual(automation.store.automations, untouched, "どれも変わらない")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "選択も動かない")
  }

  /// 自動化が 0 件なら、欄の ↑↓ は何もしない（移る行が無い）。
  func testWithNoAutomationsTheFieldIsTheOnlyStop() {
    let model = board([])
    let automation = model.automation
    XCTAssertEqual(automation.place, .request)

    send(.downArrow, to: automation)
    XCTAssertEqual(automation.place, .request, "欄の ↓ は何もしない")
    send(.upArrow, to: automation)
    XCTAssertEqual(automation.place, .request, "欄の ↑ は何もしない")
    XCTAssertEqual(automation.hints.map(\.label), [.boardAskHint], "移る先が無いので ↓ の案内を出さない")
  }
}
