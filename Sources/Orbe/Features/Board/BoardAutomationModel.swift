import Observation
import SwiftUI

/// ボードの自動化の部品の状態（@Observable）。部品は依頼の欄・一覧・右の欄（詳細か案内）で 1 つ。自動化・回・走っているか・次の
/// 時刻は唯一の正（走らせ役とストア）から毎回読み、写さない。持つのは選択（同一性）・地図に居るかと欄の中身だけ。ストアが変わったら
/// `reconcile()` で選択を付け直す（ビューの `.onChange` が届ける）。だから裏の回・AI の変更・⌘⇧X での操作がそのまま映る。
///
/// 欄は一覧の上の 1 段で、欄と一覧の行は 1 つの選択の同一性を分け合う（⌘⇧X で入力の行き先と一覧の行が 1 つの選択なのと
/// 同じ）。選ばれて見えるのは常に 1 か所で、焦点の場所は選択から決まる。↑↓ は欄と行の並びを端で巡回する。焦点が外から
/// 部品へ入ると欄から始まり（⌘⇧X が開くと入力欄に焦点があるのと同じ）、中での当て直しは選んでいる場所へ戻る。
///
/// 詳細の地図は、一覧で選んだ自動化の部品を選ぶ焦点の場所（一覧の ⇥ で入り、⇧⇥ / esc で一覧へ戻る）。一覧と地図は親子で、
/// 地図に居る間も一覧の行は選んだまま残る。部品の選択は覚えている部品で、それが「選ばれている」のは地図に居る間だけ（地図の
/// 選択の地・カード・地図の ↵ はすべて `selectedPart` を読む）。一覧の選択が別の段に替わると、地図から出て部品の選択を先頭へ
/// 戻す。
///
/// 一覧の行の → で開くサブメニュー「通知」は、選んでいる行の付属で、焦点の場所を増やさない。対象はいつも選んでいる自動化で、
/// 選んでいる段が変わる・地図へ移ると閉じる（行が一覧の見える範囲から外れたときはビューが閉じる）。
@Observable final class BoardAutomationModel {
  /// 焦点の場所。
  enum Place: Hashable {
    case request
    case list
    case map
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
    didSet {
      guard list.selectedID != oldValue.selectedID else { return }
      notifyCursor = nil
      inMap = false
      partList = ListState()
    }
  }
  /// 部品の選択（覚えている部品の鍵）。
  private(set) var partList = ListState<String>()
  /// 地図に居るか。一覧で自動化を選んでいる間だけ true になりうる。
  private(set) var inMap = false {
    didSet { if inMap { notifyCursor = nil } }
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
    if inMap { return .map }
    if case .automation = list.selectedID { return .list }
    return .request
  }

  /// 選んでいる自動化。欄を選んでいる間は nil（詳細の代わりに案内を出す）。
  var selectedAutomation: Automation? {
    guard case .automation(let id) = list.selectedID else { return nil }
    return store.automation(id)
  }

  /// 選んでいる自動化の部品の並び（地図の行の順）。
  var partIDs: [String] { selectedAutomation?.graph.byDepth.map(\.key) ?? [] }

  /// 選ばれている部品。地図に居る間だけ、覚えている部品を返す。
  var selectedPart: String? {
    guard inMap, let key = partList.selectedID, partIDs.contains(key) else { return nil }
    return key
  }

  // ビューは自動化そのものに触れず、次の値と立ち位置だけを読む。

  /// 一覧の行の値。
  func summary(_ id: Int, text: AutomationText) -> BoardAutomationSummary? {
    guard let automation = store.automation(id) else { return nil }
    let next = automation.graph.nodes.compactMap { node in
      runner.nextRunAt(automation, part: node.key).map { (key: node.key, at: $0) }
    }.min { $0.at < $1.at }
    return BoardAutomationSummary(automation, text: text, next: next?.key)
  }

  /// 詳細の値。
  func detail(_ id: Int, text: AutomationText) -> BoardAutomationDetailValue? {
    guard let automation = store.automation(id) else { return nil }
    return BoardAutomationDetailValue(
      automation, text: text, running: { self.runner.isRunning(id, $0) },
      open: store.shelvedProposals(of: id).count)
  }

  /// 選ばれている部品のカードの値。地図に居なければ nil。
  func card(text: AutomationText, now: Date) -> BoardAutomationPartValue? {
    guard let automation = selectedAutomation, let key = selectedPart else { return nil }
    return BoardAutomationPartValue(
      automation, part: key, text: text, running: runner.isRunning(automation.id, key),
      next: runner.nextRunAt(automation, part: key, now: now))
  }

  /// 描くときの文。暦の今日は描くときの今から導く（開きっぱなしの画面で日をまたいでも「今日」が古くならない）。
  func text(_ l10n: LocalizationStore, now: Date) -> AutomationText {
    let timeZone = runner.calendar().timeZone
    return AutomationText(l10n: l10n, today: .today(now, timeZone: timeZone), timeZone: timeZone)
  }

  /// ストアが変わったあとの付け直し。同一性が今の段にあればそのまま、無ければ同じ位置（末尾で頭打ち）の段へ。行がすべて
  /// 消えれば欄になる。部品も同一性で付け直し、消えたら同じ位置の部品へ。地図に居る間に選んでいた自動化が消えたら一覧へ戻る
  /// （移った先の自動化の部品を勝手に選ばない）。
  func reconcile() {
    list.reconcile(stops)
    partList.reconcile(partIDs)
  }

  // MARK: - 焦点の場所

  /// 部品の中で焦点を移す（クリックから）。欄なら欄を選び、欄から一覧へ移ったら一覧の先頭の行を選ぶ（行が無ければ欄のまま）。
  /// 地図から一覧へは選んでいる行のまま。地図へは覚えている部品へ。
  func go(_ place: Place) {
    if place != self.place {
      switch place {
      case .request: list.select(.request, in: stops)
      case .list:
        if inMap {
          inMap = false
        } else if let first = ids.first {
          list.select(.automation(first), in: stops)
        }
      case .map: enterMap()
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
    inMap = false
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
  /// キー、地図では部品で効くキー、サブメニューを開いている間はその中のキー。
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
    func hand(_ operation: BoardAutomationHand.Operation) -> BoardKeyHint {
      BoardKeyHint(operation.key, operation.title(paused: paused))
    }
    if inMap {
      return [
        BoardKeyHint("↑↓", .boardHintParts), hand(.flow(.part)),
        BoardKeyHint("⇧⇥", .boardHintToList),
      ]
    }
    return [
      BoardKeyHint("↑↓", .boardHintSelect), hand(.togglePause), hand(.flow(.ends)),
      BoardKeyHint("→", .boardNotifyTitle), BoardKeyHint("⌘↵", .boardAskFixHint), hand(.delete),
      BoardKeyHint("⇥", .boardHintToParts),
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

  /// 行のクリック。一覧に居る（部品は選ばれていない）。
  func tap(_ id: Int) {
    onRefusal(nil)
    inMap = false
    list.select(.automation(id), in: stops)
    focusToken &+= 1
  }

  /// 選んでいる自動化への手の操作。止める ⇄ 再開で行が沈んでも浮いても、選択は同じ自動化に付いていく。部品まで流すのは
  /// 選ばれている部品だけで、地図に居なければ何もしない。
  func perform(_ operation: BoardAutomationHand.Operation) {
    guard let automation = selectedAutomation else { return }
    onRefusal(nil)
    if let refusal = BoardAutomationHand.perform(
      operation, on: automation, part: selectedPart, runner: runner)
    {
      onRefusal(refusal.message)
    }
    reconcile()
    list.follow()
  }

  // MARK: - 地図

  /// 地図へ入る。覚えている部品（初めて・一覧で別の自動化を選んだ後は先頭）が選ばれる。自動化を選んでいなければ何もしない。
  func enterMap() {
    guard selectedAutomation != nil else { return }
    onRefusal(nil)
    partList.reconcile(partIDs)
    inMap = true
    focusToken &+= 1
  }

  /// 一覧へ戻る。一覧の行はそのまま。
  func leaveMap() {
    guard inMap else { return }
    onRefusal(nil)
    inMap = false
    focusToken &+= 1
  }

  /// 地図の ↑↓。端で止まり巡回しない。
  func movePart(_ direction: Int) {
    guard inMap else { return }
    onRefusal(nil)
    let ids = partIDs
    guard let index = partList.selectedID.flatMap({ ids.firstIndex(of: $0) }) else { return }
    let target = index + direction
    guard ids.indices.contains(target) else { return }
    partList.select(ids[target], in: ids)
  }

  /// 地図の部品の行のクリック。その部品を選んで地図に居る。
  func tapPart(_ key: String) {
    guard selectedAutomation != nil else { return }
    onRefusal(nil)
    partList.select(key, in: partIDs)
    inMap = true
    focusToken &+= 1
  }

  /// カードのボタン。その部品を選んで地図に居て、その部品まで流す。
  func flow(to key: String) {
    tapPart(key)
    perform(.flow(.part))
  }

  /// 地図の器のキー。↑↓・↵（`BoardAutomationHand.stroke` に任せる）・⇧⇥ / esc のほかは何も起こさず、どれも握る（焦点を
  /// ボードの外へ逃がさない）。
  func handleMapKey(_ press: KeyPress) -> KeyPress.Result {
    if let stroke = BoardAutomationHand.stroke(press, at: .map) {
      if case .press(let operation) = stroke { perform(operation) }
    } else if press.key == .backtab || press.key == .escape
      || (press.key == .tab && press.modifiers.contains(.shift))
    {
      if press.phase == .down { leaveMap() }
    } else if press.key == .upArrow || press.key == .downArrow,
      !press.modifiers.contains(.command)
    {
      movePart(press.key == .upArrow ? -1 : 1)
    }
    return .handled
  }

  /// 一覧の器のキー。サブメニューを開いている間はそちらへ回す。↑↓・→・⇥・`BoardAutomationHand.stroke` に任せるキー・⌘↵ の
  /// ほかは何も起こさず、どれも握る（⇧⇥ で焦点をボードの外へ逃がさない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if let cursor = notifyCursor {
      handleNotifyKey(press, cursor)
    } else if press.key == .rightArrow, press.modifiers.isDisjoint(with: Self.chords) {
      if press.phase == .down { openNotify() }
    } else if press.key == .tab, press.modifiers.isDisjoint(with: Self.chords) {
      if press.phase == .down { enterMap() }
    } else if let stroke = BoardAutomationHand.stroke(press, at: .list) {
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
    notifyCursor = Self.notifyChoices.firstIndex(of: automation.notify) ?? 0
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
    guard let automation = selectedAutomation, automation.notify != notify else {
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
}
