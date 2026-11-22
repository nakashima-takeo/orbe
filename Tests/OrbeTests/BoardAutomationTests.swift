import AppKit
import XCTest

@testable import Orbe

/// ボードの自動化のウィジェット——一覧の並びと、キーとクリックが実際に届く先（依頼の欄・一覧・地図の焦点、欄の文字、詳細の
/// スクロール）と、ほかの口の変更をビューが付け直しへ届ける配線。本物の `BoardView`（中身は SwiftUI）を実窓に載せ、実
/// `NSEvent` のキーとクリックを届ける。キーの判断そのものは `BoardAutomationKeyTests` が値で確かめる。走らせ役は取得が
/// 終わらない偽物で、本物の claude は起きない。
///
/// 壊れると何が起きるか: 前回が失敗した自動化が一覧の上に来ず、壊れた取得に気づけない。走り出すたびに行が跳ねる。ほかの口
/// （AI・⌘⇧X）が、ボードで選んでいる自動化やノードを消すと選択が宙に浮き、詳細が消えてキーが効かなくなる。
@MainActor
final class BoardAutomationTests: PaletteCardWindowTestCase {
  enum Key {
    static let a: UInt16 = 0
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let space: UInt16 = 49
    static let enter: UInt16 = 36
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let left: UInt16 = 123
    static let right: UInt16 = 124
  }

  // 見本『Home』の 4 件（DesignSceneFixtures+Board）。
  static let slack = 1
  static let github = 2
  static let failingBacklog = 3
  static let pausedGmail = 4

  /// `samples` を省くと見本の 4 件。
  func board(_ samples: [AutomationSample]? = nil) -> BoardModel {
    BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(
          samples ?? DesignSceneFixtures.boardAutomationSamples())),
      widgets: [.automation])
  }

  /// 見本の 4 件を置いたままの自動化（置き方は決定論なので、別の DB に置いても同じ値になる）。
  var untouched: [Automation] {
    DesignSceneFixtures.automationStore(DesignSceneFixtures.boardAutomationSamples()).automations
  }

  /// ボードを実窓に載せ、ボードを選んだときと同じ当て直し（`focus()`）で焦点を中へ入れる。ウィジェットは欄から始まる。
  func mount(_ model: BoardModel, height: CGFloat = 700) -> NSWindow {
    let window = host(
      BoardView(
        model: model, translucency: ChromeTranslucency(),
        localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver()),
      size: NSSize(width: 1200, height: height))
    model.focus()
    flush(window)
    return window
  }

  /// 実機の矢印キーは numericPad と function の修飾を伴って届く。
  func down(_ window: NSWindow) {
    send(Key.down, "\u{F701}", [.numericPad, .function], to: window)
  }

  func up(_ window: NSWindow) {
    send(Key.up, "\u{F700}", [.numericPad, .function], to: window)
  }

  func right(_ window: NSWindow) {
    send(Key.right, "\u{F703}", [.numericPad, .function], to: window)
  }

  func left(_ window: NSWindow) {
    send(Key.left, "\u{F702}", [.numericPad, .function], to: window)
  }

  // MARK: - 並び

  func testRowsAreFailingThenActiveThenPausedAndRunningDoesNotReorderThem() throws {
    let automation = board().automation
    XCTAssertEqual(
      automation.ids, [Self.failingBacklog, Self.slack, Self.github, Self.pausedGmail],
      "前回が失敗 → それ以外 → 止めている。群の中は ID 順")

    try automation.runner.flow(Self.github, to: .ends)
    XCTAssertTrue(automation.runner.isRunning(Self.github), "前提: 走っている")

    XCTAssertEqual(
      automation.ids, [Self.failingBacklog, Self.slack, Self.github, Self.pausedGmail],
      "走り出しても行は動かない")
  }

  // MARK: - キー

  // MARK: - 追従

  /// ほかの口（AI・⌘⇧X）が選んでいる自動化を消すと、ボードは同じ位置の行を選び、キーはその行に効く。
  func testDeletionElsewhereMovesTheSelectionToTheSamePosition() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)
    down(window)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.slack, "前提")

    try automation.runner.delete(Self.slack)
    flush(window)

    XCTAssertEqual(automation.selectedAutomation?.id, Self.github)
    send(Key.space, " ", to: window)
    XCTAssertEqual(automation.store.automation(Self.github)?.paused, true)
  }

  /// 地図で選んでいるノードをほかの口（AI）の書き換えが外すと、地図は同じ位置の段を選び、キーはその段から効く。
  func testRemovingTheSelectedNodeElsewhereMovesTheMapToTheSamePosition() throws {
    let model = board(DesignSceneFixtures.boardMapSamples())
    let automation = model.automation
    let window = mount(model)
    down(window)
    right(window)
    for _ in 0..<12 where automation.selectedNodeKey != "digest" { down(window) }
    XCTAssertEqual(automation.selectedNodeKey, "digest", "前提")
    let current = try XCTUnwrap(automation.selectedAutomation)
    let position = try XCTUnwrap(
      automation.selectedMapStop.flatMap { automation.mapStops.firstIndex(of: $0) })
    var definition = current.definition
    definition.nodes.removeAll { $0.key == "digest" }

    _ = try automation.runner.set(current.id, version: current.version, definition)
    flush(window)

    XCTAssertEqual(automation.place, .map)
    XCTAssertEqual(
      automation.selectedMapStop, automation.mapStops[min(position, automation.mapStops.count - 1)],
      "外したノードと同じ位置の段")
    let moved = automation.selectedNodeKey
    up(window)
    XCTAssertNotEqual(automation.selectedNodeKey, moved, "地図の ↑ が効く")
  }

  /// 定義を読めない自動化をほかの口で消しても、ボードは同じ位置の行を選ぶ（一覧の並びは読める自動化と読めない自動化を合わせた
  /// もの）。
  func testDeletingAnUnreadableAutomationElsewhereMovesTheSelectionToTheSamePosition() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(
          store: DesignSceneFixtures.boardUnreadableStore())),
      widgets: [.automation])
    let automation = model.automation
    let window = mount(model)
    down(window)
    XCTAssertEqual(automation.selectedUnreadable?.id, 2, "前提")

    try automation.runner.delete(2)
    flush(window)

    let first = try XCTUnwrap(automation.ids.first)
    XCTAssertEqual(automation.list.selectedID, .automation(first), "消えた行と同じ位置の行")
    XCTAssertNotNil(automation.selectedAutomation)
  }
}
