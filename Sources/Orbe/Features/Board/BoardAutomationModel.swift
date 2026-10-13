import Observation
import SwiftUI

/// ボードの自動化の部品の状態（@Observable）。部品は依頼の欄・一覧・右の欄（詳細か案内）で 1 つ。自動化・回・走っているか・次の
/// 時刻は唯一の正（走らせ役とストア）から毎回読み、写さない。持つのは選択（同一性）と欄の中身だけ。ストアが変わったら
/// `reconcile()` で選択を付け直す（ビューの `.onChange` が届ける）。だから裏の回・AI の変更・⌘⇧X での操作がそのまま映る。
///
/// 欄は一覧の上の 1 段で、欄と一覧の行は 1 つの選択の同一性を分け合う（⌘⇧X で入力の行き先と一覧の行が 1 つの選択なのと
/// 同じ）。選ばれて見えるのは常に 1 か所で、焦点の場所は選択から決まる。↑↓ は欄と行の並びを端で巡回する。焦点が外から
/// 部品へ入ると欄から始まり（⌘⇧X が開くと入力欄に焦点があるのと同じ）、中での当て直しは選んでいる場所へ戻る。
///
/// 一覧の行の → で開くサブメニュー「通知」は、選んでいる行の付属で、焦点の場所を増やさない。対象はいつも選んでいる自動化で、
/// 選んでいる段が変わると閉じる（行が一覧の見える範囲から外れたときはビューが閉じる）。
@Observable final class BoardAutomationModel {
  /// 焦点の場所。
  enum Place: Hashable {
    case request
    case list
  }

  /// 選べる段: 欄か、一覧の自動化の行。
  enum Stop: Hashable {
    case request
    case automation(Int)
  }

  /// サブメニュー「通知」の行の並び（通知しない・メニューバー・通知センター）。
  static let notifyChoices: [AutomationNotify?] = [nil] + AutomationNotify.allCases

  let runner: AutomationRunner
  private(set) var list = ListState<Stop>() {
    didSet { if list.selectedID != oldValue.selectedID { notifyCursor = nil } }
  }
  /// サブメニュー「通知」で選んでいる行（`notifyChoices` の番号）。nil は閉じている。
  private(set) var notifyCursor: Int?
  /// 欄の文字（入力欄の binding）。変われば断りを消す。
  var requestText = "" {
    didSet { if requestText != oldValue { onRefusal(nil) } }
  }
  /// 進むたびに、焦点がボードの中にあればビューが焦点を `place` へ当て直し、外にあれば合図を捨てる。
  private(set) var focusToken = 0
  /// ボードが受け取った最後の合図（捨てたものを含む）。
  @ObservationIgnored private var deliveredFocusToken = 0

  /// 依頼の欄の文か直しを頼む。ボードの配線が出どころを付けて秘書の口へ渡し、受けなければ断りを返す。
  @ObservationIgnored var onAsk: (SecretaryAsk) -> Secretary.Refusal? = { _ in .claudeMissing }
  /// ボードの断りの枠へ置く（nil は消す）。
  @ObservationIgnored var onRefusal: (L10nKey?) -> Void = { _ in }

  init(runner: AutomationRunner) {
    self.runner = runner
    reconcile()
  }

  var store: AutomationStore { runner.store }

  /// `now` での立ち位置で並べた自動化: 前回が失敗（止めていない）→ それ以外（止めていない）→ 止めている。群の中は ID 順。
  /// 描く経路は描くときの今を、描かない経路は走らせ役の今を渡す。
  func standings(at now: Date) -> [BoardAutomationStanding] {
    store.automations.map { BoardAutomationStanding($0, runner: runner, now: now) }
      .sorted { ($0.group, $0.id) < ($1.group, $1.id) }
  }

  var ids: [Int] { standings(at: runner.now()).map(\.id) }

  /// 選べる段の並び（欄が先頭、続いて一覧の行）。
  var stops: [Stop] { [.request] + ids.map(Stop.automation) }

  var place: Place {
    if case .automation = list.selectedID { .list } else { .request }
  }

  /// 選んでいる自動化。欄を選んでいる間は nil（詳細の代わりに案内を出す）。
  var selectedAutomation: Automation? {
    guard case .automation(let id) = list.selectedID else { return nil }
    return store.automation(id)
  }

  /// 自動化 1 つのボードの描画用の値。ビューは自動化そのものに触れず、これと立ち位置だけを読む。
  func summary(_ id: Int, text: AutomationText) -> BoardAutomationSummary? {
    store.automation(id).map { BoardAutomationSummary($0, text: text) }
  }

  /// 描くときの文。暦の今日は描くときの今から導く（開きっぱなしの画面で日をまたいでも「今日」が古くならない）。
  func text(_ l10n: LocalizationStore, now: Date) -> AutomationText {
    let timeZone = runner.calendar().timeZone
    return AutomationText(l10n: l10n, today: .today(now, timeZone: timeZone), timeZone: timeZone)
  }

  /// ストアが変わったあとの付け直し。同一性が今の段にあればそのまま、無ければ同じ位置（末尾で頭打ち）の段へ。行がすべて
  /// 消えれば欄になる。
  func reconcile() {
    list.reconcile(stops)
  }

  // MARK: - 焦点の場所

  /// 部品の中で焦点を移す（クリックから）。欄なら欄を選び、欄から一覧へ移ったら一覧の先頭の行を選ぶ。行が無ければ欄のまま。
  func go(_ place: Place) {
    if place != self.place {
      switch place {
      case .request: list.select(.request, in: stops)
      case .list: if let first = ids.first { list.select(.automation(first), in: stops) }
      }
    }
    focusToken &+= 1
  }

  /// 焦点が外から入った。欄を選ぶ（一覧で選んでいた行は保たない。⌘⇧X が開き直すたびに選択を初めからにするのと同じ）。
  func enter() {
    list.select(.request, in: stops)
    focusToken &+= 1
  }

  /// 外から行き先を指して入る（ピル・通知センターのクリックから）。入り方の既定（欄から）の後に呼び、行き先の指定がそれに
  /// 勝つ。自動化が在ればその行を選んで焦点を一覧へ、無ければ欄を選ぶ。
  func open(_ id: Int) {
    onRefusal(nil)
    if !list.select(.automation(id), in: stops) { list.select(.request, in: stops) }
    focusToken &+= 1
  }

  /// 中での当て直し。選んでいる場所へ戻る。
  func refocus() {
    focusToken &+= 1
  }

  /// 届いていない合図があれば受け取り、当てる場所を返す。部品は焦点が外にある間にも置かれて現れるので、現れただけでは焦点を
  /// 動かさない。受け取るのはボード（`BoardModel.takeFocusRequest()`）だけ。
  func takeFocusRequest() -> Place? {
    guard focusToken != deliveredFocusToken else { return nil }
    deliveredFocusToken = focusToken
    return place
  }

  /// フッターの左に出すキー。欄では送る・一覧へ移るキー（一覧が空なら移る先が無いので出さない）、一覧では選んだ自動化で効く
  /// キー、サブメニューを開いている間はその中のキー。
  var hints: [BoardKeyHint] {
    if notifyCursor != nil {
      return [
        BoardKeyHint("↑↓", .boardHintSelect), BoardKeyHint("↵", .boardHintChoose),
        BoardKeyHint("←", .boardHintBack),
      ]
    }
    guard let selectedAutomation else {
      return [BoardKeyHint("↵", .boardAskHint)]
        + (ids.isEmpty ? [] : [BoardKeyHint("↓", .boardHintToList)])
    }
    let paused = selectedAutomation.paused
    func hand(_ operation: AutomationHand.Operation) -> BoardKeyHint {
      BoardKeyHint(operation.key, operation.title(paused: paused))
    }
    return [
      BoardKeyHint("↑↓", .boardHintSelect), hand(.togglePause), hand(.runNow),
      BoardKeyHint("→", .boardNotifyTitle), BoardKeyHint("⌘↵", .boardAskFixHint), hand(.delete),
    ]
  }

  // MARK: - 選択

  /// ↑↓（欄でも一覧でも）。欄と行の並びを端で巡回する。欄と一覧をまたげば焦点も移る。
  func move(_ direction: Int) {
    onRefusal(nil)
    let before = place
    list.move(direction, in: stops)
    if place != before { focusToken &+= 1 }
  }

  /// 行のクリック。
  func tap(_ id: Int) {
    onRefusal(nil)
    list.select(.automation(id), in: stops)
    focusToken &+= 1
  }

  /// 選んでいる自動化への手の操作。止める ⇄ 再開で行が沈んでも浮いても、選択は同じ自動化に付いていく。
  func perform(_ operation: AutomationHand.Operation) {
    guard let automation = selectedAutomation else { return }
    onRefusal(nil)
    if let refusal = AutomationHand.perform(operation, on: automation, runner: runner) {
      onRefusal(refusal.message)
    }
    reconcile()
    list.follow()
  }

  /// ⌘↵。選んでいる自動化の直しをその場で頼む。頼む相手は今のストアから引き、もう無ければ頼まずに断る。
  func askFix() {
    guard case .automation(let id) = list.selectedID else { return }
    onRefusal(nil)
    guard let automation = store.automation(id) else { return onRefusal(.boardAskFixGone) }
    ask(.automationFix(automation))
  }

  /// 一覧の器のキー。サブメニューを開いている間はそちらへ回す。↑↓・→・`AutomationHand.stroke` に任せるキー・⌘↵ のほかは
  /// 何も起こさず、どれも握る（⇥ で焦点をボードの外へ逃がさない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if let cursor = notifyCursor {
      handleNotifyKey(press, cursor)
    } else if press.key == .rightArrow, press.modifiers.isDisjoint(with: Self.chords) {
      if press.phase == .down { openNotify() }
    } else if let stroke = AutomationHand.stroke(press) {
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

  // MARK: - 通知

  /// 選んでいる自動化のサブメニューを開く。選んでいる行を一覧の見える範囲へ引き寄せてから開く（メニューは行の横に出るので、
  /// 行が見えていないと別の行の横に出る）。選んでいる行は今の設定から。
  func openNotify() {
    guard let automation = selectedAutomation else { return }
    onRefusal(nil)
    list.follow()
    notifyCursor = Self.notifyChoices.firstIndex(of: automation.definition.notify) ?? 0
  }

  /// サブメニューの ↑↓。端で巡回する。
  func moveNotify(_ direction: Int) {
    guard let cursor = notifyCursor else { return }
    let count = Self.notifyChoices.count
    notifyCursor = (cursor + direction + count) % count
  }

  func closeNotify() {
    notifyCursor = nil
  }

  /// 選んでいる自動化の通知を `notify` に決めて閉じる。今の定義の通知だけを差し替えて走らせ役の書き換えの口へ渡す（通知は
  /// 何をするかに入らないので、走っている回は止まらない）。同じ値なら書かない。消えていたら黙る（行き違い）。
  func chooseNotify(_ notify: AutomationNotify?) {
    notifyCursor = nil
    guard let automation = selectedAutomation, automation.definition.notify != notify else {
      return
    }
    var definition = automation.definition
    definition.notify = notify
    _ = try? runner.set(automation.id, definition)
    reconcile()
  }

  /// サブメニューのキー。↑↓ は端で巡回し、↵ で決め、← / esc で何もせず閉じる。ほかは下の一覧の操作を起こさずに握る。
  private func handleNotifyKey(_ press: KeyPress, _ cursor: Int) {
    switch press.key {
    case .upArrow, .downArrow:
      guard !press.modifiers.contains(.command) else { return }
      moveNotify(press.key == .upArrow ? -1 : 1)
    case .return:
      guard press.phase == .down, press.modifiers.isDisjoint(with: Self.chords) else { return }
      chooseNotify(Self.notifyChoices[cursor])
    case .leftArrow, .escape:
      closeNotify()
    default:
      break
    }
  }

  /// 修飾なしのキーとみなさない修飾（矢印キーが伴う numericPad・function は含めない）。
  private static let chords: EventModifiers = [.command, .option, .control, .shift]

  // MARK: - 依頼の欄

  /// 欄のキー。↑↓ は段を移り、esc は ↓ と同じく一覧の先頭の行へ。⇥・⇧⇥ は何もせずに握る（焦点をボードの外へ逃がさない）。
  /// 変換中のキーは窓が IME へ渡すので、ここへは来ない。ほかは入力欄へ流す。
  func handleRequestKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      guard !press.modifiers.contains(.command) else { return .ignored }
      move(press.key == .upArrow ? -1 : 1)
    case .escape:
      if press.phase == .down { move(1) }
    case .tab, .backtab:
      break
    default:
      return .ignored
    }
    return .handled
  }

  /// 欄の ↵。打った文を頼み、受けたら欄を空にする。断られたら欄を残す。空の欄は黙る。
  func send() {
    onRefusal(nil)
    if ask(.text(requestText)) { requestText = "" }
  }

  /// 頼んで、受けたかを返す。受けられなければ断りを置く。空の頼みは黙って受けない。
  @discardableResult private func ask(_ ask: SecretaryAsk) -> Bool {
    switch onAsk(ask) {
    case nil: return true
    case .claudeMissing: onRefusal(.boardAskClaudeMissing)
    case .unavailable: onRefusal(.boardAskUnavailable)
    case .empty: break
    }
    return false
  }
}
