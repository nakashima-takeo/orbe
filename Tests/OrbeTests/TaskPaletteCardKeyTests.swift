import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `TaskPaletteCard` を実 `NSWindow` に載せ、実 `NSEvent` のキーとクリックを届けて、キーの判断（`TaskPaletteKeyTests`
/// が値で確かめる）の外側を固定する: 実機のキーがモデルの受けるキーの値になる形（矢印キーのフラグ・CapsLock・⌫・⇧⇥・
/// リピート）、握ったキーが入力欄へ届かず、流したキーが入力欄と ↵ の確定（`onSubmit`）へ届くこと、焦点の行き先、クリック、
/// agent の変更をカードが付け直しへ届ける配線。
///
/// 壊れると何が起きるか: 入力欄に文字があるのに space がタスクを完了にする、文字があるときの ⌘⌫ が入力を消さずにタスクを
/// 消す。CapsLock を入れていると space が効かない。右の欄で打った文字が編集欄に届かず一覧の入力に入る、⇥ で焦点がカードの
/// 外へ逃げて以後のキーが効かない。agent がタスクを消した直後の space が、消えたタスクに向かう。どれもモデル単体では
/// 再現せず、実際に描いてキーを届けないと分からない。
@MainActor
final class TaskPaletteCardKeyTests: PaletteCardWindowTestCase {
  enum Key {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let enter: UInt16 = 36
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
  }

  /// 実機の矢印キーは numericPad と function の修飾を伴って届く。
  let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

  func model() -> TaskPaletteModel { TaskPaletteSamples.threeTodos() }

  func mount(
    _ model: TaskPaletteModel, width: CGFloat = 960, detailWidth: CGFloat = 340
  ) -> NSWindow {
    let window = host(
      NSHostingView(
        rootView: TaskPaletteCard(model: model, detailWidth: detailWidth)
          .frame(width: width, height: 600)
          .environment(\.localization, LocalizationStore(language: .ja))),
      size: NSSize(width: width + 40, height: 640))
    awaitFieldFocus(window)
    return window
  }

  /// ヘッダーの入力欄（カード左上の「❯」の右）をクリックする。窓はカードの大きさに揃うので、窓座標
  /// （原点は左下）でヘッダーの縦中央を叩く。
  func click(atFieldOf window: NSWindow) throws {
    let content = try XCTUnwrap(window.contentView)
    click(NSPoint(x: 120, y: content.bounds.height - 28), in: window)
  }

  func arrow(
    _ keyCode: UInt16, _ extra: NSEvent.ModifierFlags = [], repeating: Bool = false,
    to window: NSWindow
  ) {
    let character: NSEvent.SpecialKey =
      switch keyCode {
      case Key.left: .leftArrow
      case Key.right: .rightArrow
      case Key.up: .upArrow
      default: .downArrow
      }
    send(
      keyCode, String(UnicodeScalar(character.rawValue)!), arrowFlags.union(extra),
      repeating: repeating, to: window)
  }

  func type(_ text: String, into window: NSWindow) {
    for character in text { send(0, String(character), to: window) }
  }

  func status(_ model: TaskPaletteModel, _ id: Int) -> TaskItem.Status? {
    model.store.tasks.first { $0.id == id }?.status
  }

  // MARK: - 入力欄（一覧）

  func testSpaceCompletesTheSelectedTaskOnlyWhileTheFieldIsEmpty() {
    let model = model()
    let window = mount(model)

    send(Key.space, " ", to: window)
    XCTAssertEqual(status(model, 3), .done, "空の入力欄の space は選んだタスクを完了にする")

    type("b", into: window)
    send(Key.space, " ", to: window)
    XCTAssertEqual(model.query, "b ", "文字があるときの space は空白を打つ")
    XCTAssertEqual(status(model, 2), .todo)
  }

  func testSpaceWithCapsLockOnStillCompletesTheSelectedTask() {
    let model = model()
    let window = mount(model)

    send(Key.space, " ", .capsLock, to: window)

    XCTAssertEqual(status(model, 3), .done)
  }

  func testEnterCompletesTheSelectedTaskAndAddsFromTheAddRow() throws {
    let model = model()
    let window = mount(model)

    send(Key.enter, "\r", to: window)
    XCTAssertEqual(status(model, 3), .done)

    type("新しい", into: window)
    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "新しい" })
    XCTAssertEqual(model.query, "")
  }

  /// 押し始めを見ていない ↵ のリピートだけが入力欄に届いても、完了にも追加にもならない。
  func testEnterKeyRepeatAloneInTheFieldDoesNothing() {
    let model = model()
    let window = mount(model)

    send(Key.enter, "\r", repeating: true, to: window)
    type("新しい", into: window)
    send(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.status), [.todo, .todo, .todo], "完了にしない")
    XCTAssertEqual(model.store.tasks.count, 3, "追加しない")
    XCTAssertEqual(model.query, "新しい")
  }

  func testCommandBackspaceWithTextEditsTheFieldInsteadOfDeleting() {
    let model = model()
    let window = mount(model)
    type("a", into: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.selectedID, .task(1), "前提: 一致したタスクを選んだ")

    send(Key.delete, "\u{7F}", .command, to: window)

    XCTAssertEqual(model.store.tasks.count, 3, "文字があるときはタスクを消さない")
    XCTAssertEqual(model.query, "", "入力欄の文字を行頭まで消す")
  }

  func testTabAndShiftTabCycleTheTabsWhileTheFieldKeepsTheKeys() {
    let model = model()
    let window = mount(model)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .github)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .automation)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .tasks, "3 つのタブを巡る")

    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .automation, "⇧⇥ は逆に巡る")

    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .github)

    send(Key.tab, "\u{19}", .shift, to: window)
    type("x", into: window)
    XCTAssertEqual(model.tab, .tasks)
    XCTAssertEqual(model.query, "x", "焦点は入力欄に残り、続けて打てる")
  }

  /// 選ぶ状態の ⇥・⇧⇥ は選ぶ状態を保ち、焦点も入力欄に残る（タブを替えないことはモデルのテストが守る）。
  func testTabWhilePickingKeepsPickingAndTheFieldKeepsTheKeys() {
    let model = model()
    model.enterDetail()
    model.area = .detail(.addLink)
    model.beginPickingItem()
    let window = mount(model)

    send(Key.tab, "\t", to: window)
    send(Key.tab, "\u{19}", .shift, to: window)
    type("a", into: window)

    XCTAssertNotNil(model.pick)
    XCTAssertEqual(model.query, "a")
  }

  /// 期限のメニューの値を上から 3 つ続けてクリックすると、3 つともオンになり、メニューは開いたまま。カードは窓が
  /// 広いときの最大の寸法（880 幅・右の欄は 1/3）で、1 つ目をオンにするとドロップダウンの表記が伸びて次の行へ
  /// 折り返す。メニューがドロップダウンを追って動くと、2 つ目のクリックがメニューの外に当たって閉じる。
  func testClickingThreeValuesInARowKeepsTheFilterMenuOpenAndTurnsAllOn() throws {
    let model = model()
    model.toggleFilterMenu(.due)
    let window = mount(model, width: 880, detailWidth: 880 / 3)
    placeOffscreen(window)
    let content = try XCTUnwrap(window.contentView)
    let table = try XCTUnwrap(scrollViews(in: content).first)
    let tableTop = table.convert(table.bounds, to: nil).maxY
    let menu = try XCTUnwrap(scrollViews(in: content).last)
    let frame = menu.convert(menu.bounds, to: nil)

    for (row, bucket) in [TaskDueBucket.overdue, .today, .withinWeek].enumerated() {
      let y =
        frame.maxY - Theme.Space.tick - TaskPaletteRowMetrics.line * (CGFloat(row) + 0.5)
      click(NSPoint(x: frame.minX + 40, y: y), in: window)
      if row == 0 {
        XCTAssertLessThan(
          table.convert(table.bounds, to: nil).maxY, tableTop, "前提: ドロップダウンが次の行へ折り返す")
      }
      XCTAssertEqual(model.openFilterMenu, .due, "\(row + 1) つ目のクリックの後も開いたまま")
      XCTAssertTrue(model.filter.dues.contains(bucket), "\(row + 1) つ目の値がオン")
    }
  }

  /// view の木を深さ優先でたどった順のスクロール。先頭が表で、絞り込みのメニューはカードの最後に重ねるので末尾。
  private func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }

  /// agent の変更（ストアの直接の変異）は、カードが付け直しへ届ける。選んでいたタスクが消えたら、
  /// 直後の space は同じ位置に来た行に効き、消えたタスクの ID には向かわない。
  func testAgentDeletingTheSelectedTaskMovesTheSelectionBeforeTheNextKey() throws {
    let model = model()
    let window = mount(model)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.selectedID, .task(2), "前提")

    try model.store.delete(2)
    flush(window)
    send(Key.space, " ", to: window)

    XCTAssertEqual(status(model, 1), .done, "同じ位置に来た a を完了にする")
  }
}
