import Observation
import SwiftUI

/// ボードの自動追加の部品の状態（@Observable）。部品は見出し・依頼の欄・一覧・詳細で 1 つ。自動追加・回・走っているか・次の
/// 時刻は唯一の正（走らせ役とストア）から毎回読み、写さない。持つのは一覧の選択（同一性）・欄の中身・部品の中の焦点の場所だけ。
/// ストアが変わったら `reconcile()` で選択を付け直す（ビューの `.onChange` が届ける）。だから裏の回・AI の変更・⌘⇧X での
/// 操作がそのまま映る。
///
/// 焦点の場所は欄か一覧で、初めは一覧（選べばすぐ space・↵ が効く）。欄は一覧の上の 1 段で、↑↓ は欄と一覧の行を 1 つの並びと
/// して端で巡回する（⌘⇧X で入力の行き先が一覧の先頭に並ぶのと同じ）。ボードから当て直されると最後に居た場所へ戻る。
@Observable final class BoardIntakeModel {
  enum Place: Hashable {
    case request
    case list
  }

  let runner: IntakeRunner
  private(set) var list = ListState<Int>()
  /// 欄の文字（入力欄の binding）。変われば断りを消す。
  var requestText = "" {
    didSet { if requestText != oldValue { onRefusal(nil) } }
  }
  private(set) var place = Place.list
  /// 進むたびに、ビューが焦点を `place` へ当て直す。
  private(set) var focusToken = 0

  /// 自動追加の新しい依頼か直しを頼む。ボードの配線が出どころを付けて秘書の口へ渡し、受けなければ断りを返す。
  @ObservationIgnored var onAsk: (SecretaryAsk) -> Secretary.Refusal? = { _ in .claudeMissing }
  /// ボードの断りの枠へ置く（nil は消す）。
  @ObservationIgnored var onRefusal: (L10nKey?) -> Void = { _ in }

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

  // MARK: - 焦点の場所

  /// 焦点がその場所へ移った（クリック・キーのどちらからも）。
  func arrive(_ place: Place) {
    self.place = place
  }

  /// 部品の中で焦点を移す。
  func go(_ place: Place) {
    arrive(place)
    focusToken &+= 1
  }

  /// ボードからの当て直し。最後に居た場所へ戻る。
  func refocus() {
    focusToken &+= 1
  }

  /// フッターの左に出すキー。欄では送る・一覧へ移るキー（一覧が空なら移る先が無いので出さない）、一覧では選んだ自動追加で効く
  /// キー（無ければ出さない）。
  var hints: [BoardKeyHint] {
    switch place {
    case .request:
      return [BoardKeyHint("↵", .boardAskHint)]
        + (ids.isEmpty ? [] : [BoardKeyHint("↓", .boardHintToList)])
    case .list:
      guard let selected else { return [] }
      let paused = selected.intake.paused
      let hand = IntakeHand.Operation.allCases.map {
        BoardKeyHint($0.key, $0.title(paused: paused))
      }
      return [BoardKeyHint("↑↓", .boardHintSelect)] + hand.prefix(2)
        + [BoardKeyHint("⌘↵", .boardAskFixHint)] + hand.dropFirst(2)
    }
  }

  // MARK: - 一覧

  /// 一覧の ↑↓。端の行から外へ出ると欄へ移る（先頭の ↑ は真上の欄へ、末尾の ↓ は巡回して欄へ）。
  func move(_ direction: Int) {
    onRefusal(nil)
    let ids = self.ids
    guard let index = list.selectedID.flatMap({ ids.firstIndex(of: $0) }),
      ids.indices.contains(index + direction)
    else { return go(.request) }
    list.move(direction, in: ids)
  }

  /// 行のクリック。
  func tap(_ id: Int) {
    onRefusal(nil)
    list.select(id, in: ids)
    go(.list)
  }

  /// 選んでいる自動追加への手の操作。止める ⇄ 再開で行が沈んでも浮いても、選択は同じ自動追加に付いていく。
  func perform(_ operation: IntakeHand.Operation) {
    guard let intake = selected?.intake else { return }
    onRefusal(nil)
    if let refusal = IntakeHand.perform(operation, on: intake, runner: runner) {
      onRefusal(refusal.message)
    }
    reconcile()
    list.follow()
  }

  /// ⌘↵。選んでいる自動追加の直しをその場で頼む。頼む相手は今のストアから引き、もう無ければ頼まずに断る。
  func askFix() {
    guard let id = list.selectedID else { return }
    onRefusal(nil)
    guard let intake = store.intake(id) else { return onRefusal(.boardAskFixGone) }
    _ = ask(.intakeFix(intake))
  }

  /// 一覧の器のキー。↑↓・`IntakeHand` の写し・⌘↵ のほかは何も起こさず、どれも握る（⇥ で焦点をボードの外へ逃がさない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if let stroke = IntakeHand.stroke(press) {
      if case .press(let operation) = stroke { perform(operation) }
    } else if press.key == .return, press.modifiers.contains(.command) {
      if press.phase == .down { askFix() }
    } else if press.key == .upArrow || press.key == .downArrow,
      !press.modifiers.contains(.command)
    {
      move(press.key == .upArrow ? -1 : 1)
    }
    return .handled
  }

  // MARK: - 依頼の欄

  /// 欄のキー。↑↓ で一覧の行へ、esc で一覧へ戻る。⇥・⇧⇥ は何もせずに握る（焦点をボードの外へ逃がさない）。変換中のキーは窓が
  /// IME へ渡すので、ここへは来ない。ほかは入力欄へ流す。
  func handleRequestKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      guard !press.modifiers.contains(.command) else { return .ignored }
      leaveRequest(press.key == .upArrow ? -1 : 1)
    case .escape:
      if press.phase == .down { toList() }
    case .tab, .backtab:
      break
    default:
      return .ignored
    }
    return .handled
  }

  /// 欄の ↑↓。↓ は一覧の先頭、↑ は巡回して一覧の末尾の行を選んで一覧へ移る。一覧が空なら何もしない。
  func leaveRequest(_ direction: Int) {
    let ids = self.ids
    guard !ids.isEmpty else { return }
    onRefusal(nil)
    list.jump(direction > 0 ? -1 : 1, in: ids)
    go(.list)
  }

  /// 欄の esc。選択はそのまま。
  func toList() {
    onRefusal(nil)
    go(.list)
  }

  /// 欄の ↵。打った文をタスクの自動追加の新しい依頼として頼み、受けたら欄を空にする。断られたら欄を残す。空の欄は黙る。
  func send() {
    onRefusal(nil)
    if ask(.intake(requestText)) { requestText = "" }
  }

  /// 頼んで、受けたかを返す。claude が無ければ断りを置く。空の頼みは黙って受けない。
  private func ask(_ ask: SecretaryAsk) -> Bool {
    switch onAsk(ask) {
    case nil: return true
    case .claudeMissing: onRefusal(.boardAskClaudeMissing)
    case .empty: break
    }
    return false
  }
}
