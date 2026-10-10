import Observation
import SwiftUI

/// ボードの自動追加の部品の状態（@Observable）。自動追加・回・走っているか・次の時刻は唯一の正（走らせ役とストア）から毎回
/// 読み、写さない。持つのは一覧の選択（同一性）と赤の断りだけ。ストアが変わったら `reconcile()` で選択を付け直す（ビューの
/// `.onChange` が届ける）。だから裏の回・AI の変更・⌘⇧X での操作がそのまま映る。
@Observable final class BoardIntakeModel {
  let runner: IntakeRunner
  private(set) var list = ListState<Int>()
  private(set) var refusal: IntakeHand.Refusal?

  init(runner: IntakeRunner) {
    self.runner = runner
    reconcile()
  }

  var store: IntakeStore { runner.store }

  /// 立ち位置で並べた自動追加: 前回が失敗（止めていない）→ それ以外（止めていない）→ 止めている。群の中は ID 順。
  var standings: [BoardIntakeStanding] {
    store.intakes.map { BoardIntakeStanding($0, runner: runner) }
      .sorted { ($0.group, $0.id) < ($1.group, $1.id) }
  }

  var ids: [Int] { standings.map(\.id) }

  var selected: BoardIntakeStanding? {
    guard let id = list.selectedID, let intake = store.intake(id) else { return nil }
    return BoardIntakeStanding(intake, runner: runner)
  }

  /// 描くときの文。暦の今日は描くたびに走らせ役の今から導く（開きっぱなしの画面で日をまたいでも「今日」が古くならない）。
  func text(_ l10n: LocalizationStore) -> IntakeText {
    let timeZone = runner.calendar().timeZone
    return IntakeText(
      l10n: l10n, today: .today(runner.now(), timeZone: timeZone), timeZone: timeZone)
  }

  /// ストアが変わったあとの付け直し。同一性が今の行にあればそのまま、無ければ同じ位置（末尾で頭打ち）の行へ。
  func reconcile() {
    list.reconcile(ids)
  }

  /// ↑↓。端で巡回する。
  func move(_ direction: Int) {
    refusal = nil
    list.move(direction, in: ids)
  }

  /// 行のクリック。
  func tap(_ id: Int) {
    refusal = nil
    list.select(id, in: ids)
  }

  /// 選んでいる自動追加への手の操作。止める ⇄ 再開で行が沈んでも浮いても、選択は同じ自動追加に付いていく。
  func perform(_ operation: IntakeHand.Operation) {
    guard let intake = selected?.intake else { return }
    refusal = IntakeHand.perform(operation, on: intake, runner: runner)
    reconcile()
    list.follow()
  }

  /// 一覧の器のキー。↑↓ と `IntakeHand` の写しのほかは何も起こさず、どれも握る（⇥ で焦点をボードの外へ逃がさない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if let stroke = IntakeHand.stroke(press) {
      if case .press(let operation) = stroke { perform(operation) }
    } else if press.key == .upArrow || press.key == .downArrow,
      !press.modifiers.contains(.command)
    {
      move(press.key == .upArrow ? -1 : 1)
    }
    return .handled
  }
}
