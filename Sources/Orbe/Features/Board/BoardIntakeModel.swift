import Observation
import SwiftUI

/// ボードの自動追加の部品の状態（@Observable）。部品は見出し・依頼の欄・一覧・詳細で 1 つ。自動追加・回・走っているか・次の
/// 時刻は唯一の正（走らせ役とストア）から毎回読み、写さない。持つのは一覧の選択（同一性）・欄の中身・部品の中の焦点の場所だけ。
/// ストアが変わったら `reconcile()` で選択を付け直す（ビューの `.onChange` が届ける）。だから裏の回・AI の変更・⌘⇧X での
/// 操作がそのまま映る。
///
/// 焦点の場所は欄か一覧で、初めは一覧（選べばすぐ space・↵ が効く）。ボードから当て直されると最後に居た場所へ戻る。札は欄から
/// 一覧へ移ったときに外れ、ボードの外へ焦点が出ただけでは外れない。
@Observable final class BoardIntakeModel {
  enum Place: Hashable {
    case request
    case list
  }

  let runner: IntakeRunner
  private(set) var list = ListState<Int>()
  private(set) var request = BoardIntakeRequest()
  private(set) var place = Place.list
  /// 進むたびに、ビューが焦点を `place` へ当て直す。
  private(set) var focusToken = 0

  /// 欄から頼む（自動追加の新しい依頼か直し）。ボードの配線が出どころを付けて秘書の口へ渡し、受けなければ断りを返す。
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

  /// 焦点がその場所へ移った（クリック・キーのどちらからも）。欄から一覧へ移ったら札を外す（打った文字は残す）。
  func arrive(_ place: Place) {
    if self.place == .request, place == .list { request.fix = nil }
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

  /// フッターの左に出すキー。欄では送る・離れるキー、一覧では選んだ自動追加で効くキー（無ければ出さない）。
  var hints: [BoardKeyHint] {
    switch place {
    case .request:
      return request.fix == nil
        ? [BoardKeyHint("↵", .boardAskHint), BoardKeyHint("⇥", .boardHintToList)]
        : [BoardKeyHint("↵", .boardAskFixHint), BoardKeyHint("esc", .boardHintCancel)]
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

  /// ↑↓。端で巡回する。
  func move(_ direction: Int) {
    onRefusal(nil)
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

  /// ⌘↵。選んでいる自動追加の札を欄に付け、焦点を欄へ移す（直したいことを打ってから送る）。
  func requestFix() {
    guard let intake = selected?.intake else { return }
    onRefusal(nil)
    request.fix = BoardIntakeRequest.Fix(id: intake.id, name: intake.definition.name)
    go(.request)
  }

  /// 一覧の器のキー。↑↓・`IntakeHand` の写し・⌘↵・⇥（欄へ）のほかは何も起こさず、どれも握る（⇥ で焦点をボードの外へ逃がさない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if let stroke = IntakeHand.stroke(press) {
      if case .press(let operation) = stroke { perform(operation) }
    } else if press.key == .return, press.modifiers.contains(.command) {
      if press.phase == .down { requestFix() }
    } else if press.key == .tab || press.key == .backtab {
      if press.phase == .down { toRequest() }
    } else if press.key == .upArrow || press.key == .downArrow,
      !press.modifiers.contains(.command)
    {
      move(press.key == .upArrow ? -1 : 1)
    }
    return .handled
  }

  // MARK: - 依頼の欄

  /// 欄の文字（入力欄の binding）。打てば断りを消す。
  var requestText: String {
    get { request.text }
    set {
      guard newValue != request.text else { return }
      onRefusal(nil)
      request.text = newValue
    }
  }

  /// 欄のキー。⇥・⇧⇥・↓・esc で一覧へ移る（変換中のキーは窓が IME へ渡すので、ここへは来ない）。ほかは入力欄へ流す。
  func handleRequestKey(_ press: KeyPress) -> KeyPress.Result {
    guard [.tab, .backtab, .downArrow, .escape].contains(press.key) else { return .ignored }
    if press.phase == .down { toList() }
    return .handled
  }

  /// 一覧の ⇥。
  func toRequest() {
    onRefusal(nil)
    go(.request)
  }

  /// 欄の ⇥・↓・esc。
  func toList() {
    onRefusal(nil)
    go(.list)
  }

  /// 欄の ↵。札が無ければ新しい依頼、あれば今のストアから引いた相手の直しを頼む。受けたら欄を空にして札を外し、断られたら
  /// 欄と札を残す。空の欄は黙る。
  func send() {
    onRefusal(nil)
    let ask: SecretaryAsk
    if let fix = request.fix {
      guard let intake = store.intake(fix.id) else {
        return onRefusal(.boardAskFixGone)
      }
      ask = .intakeFix(intake, note: request.text)
    } else {
      ask = .intake(request.text)
    }
    switch onAsk(ask) {
    case nil:
      request = BoardIntakeRequest()
    case .claudeMissing:
      onRefusal(.boardAskClaudeMissing)
    case .empty:
      break
    }
  }
}
