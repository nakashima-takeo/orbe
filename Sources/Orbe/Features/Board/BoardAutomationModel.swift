import Observation
import SwiftUI

/// ボードの自動化の部品の状態（@Observable）。部品は依頼の欄・一覧・右の欄（詳細か案内）で 1 つ。自動化・回・走っているか・次の
/// 時刻は唯一の正（走らせ役とストア）から毎回読み、写さない。持つのは選択（同一性）・地図に居るかと欄の中身だけ。段の並びが
/// 変われば `reconcile()` で選択を付け直す（ビューの `.onChange` が届ける）。だから裏の回・AI の変更・⌘⇧X の操作がそのまま映る。
///
/// 欄は一覧の上の 1 段で、欄と一覧の行は 1 つの選択の同一性を分け合う（⌘⇧X で入力の行き先と一覧の行が 1 つの選択なのと
/// 同じ）。選ばれて見えるのは常に 1 か所で、焦点の場所は選択から決まる。↑↓ は欄と行の並びを端で巡回する。焦点が外から
/// 部品へ入ると欄から始まり（⌘⇧X が開くと入力欄に焦点があるのと同じ）、中での当て直しは選んでいる場所へ戻る。
///
/// 詳細の地図は、一覧で選んだ自動化の段（見出しの「通知」と部品）を選ぶ焦点の場所。一覧の ↵ / → で入り、← / esc で一覧へ戻る
/// （⌘⇧X の棚と候補の一覧と同じ流儀）。一覧と地図は親子で、地図に居る間も一覧の行は選んだまま残る。地図の段の選択は覚えている
/// 段で、それが「選ばれている」のは地図に居る間だけ（地図の選択の地・カード・地図の ⌘↵ はすべて `selectedMapStop` を読む）。
/// 一覧の選択が別の段に替わると、地図から出て段の選択を忘れる（次に入ると先頭の部品）。
///
/// 地図の「通知」の段で ↵ / → を押すと開くサブメニュー「通知」は、その段の付属で、焦点の場所を増やさない。地図の段が変わる・
/// 地図を出ると閉じる。
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

  /// 地図の段: 見出しの「通知」の行か、部品の行。
  enum MapStop: Hashable {
    case notify
    case node(AutomationNodeID)
  }

  /// サブメニュー「通知」の行の並び（通知しない・メニューバー・通知センター）。
  static let notifyChoices: [AutomationNotify?] = [nil] + AutomationNotify.allCases

  let runner: AutomationRunner
  private(set) var list = ListState<Stop>() {
    didSet {
      guard list.selectedID != oldValue.selectedID else { return }
      inMap = false
      mapList = ListState()
    }
  }
  /// 地図の段の選択（覚えている段）。
  private(set) var mapList = ListState<MapStop>() {
    didSet { if mapList.selectedID != oldValue.selectedID { notifyCursor = nil } }
  }
  /// 地図に居るか。一覧で自動化を選んでいる間だけ true になりうる。
  private(set) var inMap = false {
    didSet { if !inMap { notifyCursor = nil } }
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

  /// 依頼の欄の文を頼む。ボードの配線が出どころを付けて秘書の口へ渡し、受けなければ断りを返す。
  @ObservationIgnored var onAsk: (String) -> Secretary.Refusal? = { _ in .claudeMissing }
  /// ボードの断りの枠へ置く（nil は消す）。
  @ObservationIgnored var onRefusal: (L10nKey?) -> Void = { _ in }

  init(runner: AutomationRunner) {
    self.runner = runner
    reconcile()
  }

  var store: AutomationStore { runner.store }

  /// 立ち位置で並べた自動化: 失敗した部品がある・定義を読めない（止めていない）→ それ以外（止めていない）→ 止めている。群の中は
  /// ID 順。
  var standings: [BoardAutomationStanding] {
    (store.automations.map { BoardAutomationStanding($0, runner: runner) }
      + store.unreadable.map(BoardAutomationStanding.init))
      .sorted { ($0.group, $0.id) < ($1.group, $1.id) }
  }

  var ids: [Int] { standings.map(\.id) }

  /// 選べる段の並び（欄が先頭、続いて一覧の行）。
  var stops: [Stop] { [.request] + ids.map(Stop.automation) }

  var place: Place {
    if inMap { return .map }
    if case .automation = list.selectedID { return .list }
    return .request
  }

  /// 選んでいる自動化。欄・定義を読めない自動化を選んでいる間は nil。
  var selectedAutomation: Automation? {
    guard case .automation(let id) = list.selectedID else { return nil }
    return store.automation(id)
  }

  /// 選んでいる、定義を読めない自動化。
  var selectedUnreadable: AutomationUnreadable? {
    guard case .automation(let id) = list.selectedID else { return nil }
    return store.unreadable.first { $0.id == id }
  }

  /// 選んでいる自動化の地図の段の並び（「通知」、続いて部品の行の順）。
  var mapStops: [MapStop] {
    guard let automation = selectedAutomation else { return [] }
    return [.notify] + automation.graph.byDepth.map { .node($0.id) }
  }

  /// 選ばれている地図の段。地図に居る間だけ、覚えている段を返す。
  var selectedMapStop: MapStop? {
    guard inMap, let stop = mapList.selectedID, mapStops.contains(stop) else { return nil }
    return stop
  }

  /// 選ばれている部品。
  var selectedNodeId: AutomationNodeID? {
    guard case .node(let nodeId) = selectedMapStop else { return nil }
    return nodeId
  }

  /// ストアが変わったあとの付け直し。同一性が今の段にあればそのまま、無ければ同じ位置（末尾で頭打ち）の段へ。行がすべて
  /// 消えれば欄になる。地図の段も同一性で付け直し、消えたら同じ位置の段へ。地図に居る間に選んでいた自動化が消えたら一覧へ
  /// 戻る（移った先の自動化の段を勝手に選ばない）。
  func reconcile() {
    list.reconcile(stops)
    if mapList.selectedID != nil { mapList.reconcile(mapStops) }
  }

  // MARK: - 焦点の場所

  /// 部品の中で焦点を移す（クリックから）。欄なら欄を選び、欄から一覧へ移ったら一覧の先頭の行を選ぶ（行が無ければ欄のまま）。
  /// 地図から一覧へは選んでいる行のまま。地図へは覚えている段へ。
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
  /// 選ばれている部品だけで、部品が選ばれていなければ何もしない。
  func perform(_ operation: BoardAutomationHand.Operation) {
    if let broken = selectedUnreadable, operation == .delete {
      onRefusal(nil)
      try? runner.delete(broken.id)
      reconcile()
      list.follow()
      return
    }
    guard let automation = selectedAutomation else { return }
    onRefusal(nil)
    if let refusal = BoardAutomationHand.perform(
      operation, on: automation, nodeId: selectedNodeId, runner: runner)
    {
      onRefusal(refusal.message)
    }
    reconcile()
    list.follow()
  }

  // MARK: - 地図

  /// 地図へ入る。覚えている段（初めて・一覧で別の自動化を選んだ後は先頭の部品）が選ばれる。自動化を選んでいなければ何もしない。
  func enterMap() {
    let stops = mapStops
    guard stops.count > 1 else { return }
    onRefusal(nil)
    if mapList.selectedID.map(stops.contains) != true { mapList.select(stops[1], in: stops) }
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

  /// 地図の ↑↓。端で止まり巡回しない。先頭の部品の ↑ は「通知」の段。
  func moveInMap(_ direction: Int) {
    guard inMap else { return }
    onRefusal(nil)
    let stops = mapStops
    guard let index = mapList.selectedID.flatMap({ stops.firstIndex(of: $0) }) else { return }
    let target = index + direction
    guard stops.indices.contains(target) else { return }
    mapList.select(stops[target], in: stops)
  }

  /// 地図の部品の行のクリック。その部品を選んで地図に居る。
  func tapNode(_ nodeId: AutomationNodeID) {
    select(.node(nodeId))
  }

  /// 見出しの「通知」の行のクリック。その段を選んで地図に居て、サブメニューを開く。
  func tapNotify() {
    select(.notify)
    openNotify()
  }

  private func select(_ stop: MapStop) {
    guard selectedAutomation != nil else { return }
    onRefusal(nil)
    mapList.select(stop, in: mapStops)
    inMap = true
    focusToken &+= 1
  }

  /// カードの「修正を依頼」。依頼の欄に「自動化「<名前>」の部品「<名前>」の修正：」を書き（書きかけは置き換える）、焦点を欄へ
  /// 移す——続けて打って ↵ で、欄からふつうに頼む。`l10n` は画面の言語。
  func draftFix(of nodeId: AutomationNodeID, l10n: LocalizationStore) {
    guard let automation = selectedAutomation, let node = automation.graph.node(nodeId) else {
      return
    }
    draft(l10n.format(.boardAskFixDraft, automation.name, node.entity.name))
  }

  /// 定義を読めない自動化の「修正を依頼」。依頼の欄に「自動化「<名前>」の修正：<理由の原文>」を書く（読むのは AI なので
  /// 原文だけ）。
  func draftFixOfUnreadable(l10n: LocalizationStore) {
    guard let broken = selectedUnreadable else { return }
    draft(
      l10n.format(.boardAskFixAutomationDraft, BoardAutomationStanding(broken).title(l10n))
        + broken.reason)
  }

  private func draft(_ text: String) {
    requestText = text
    caretAtEnd = true
    list.select(.request, in: stops)
    focusToken &+= 1
  }

  /// 欄へ焦点が入ったとき、キャレットを末尾に置くか（書き出した直後だけ。ほかは AppKit の全選択のまま）。1 度だけ返す。
  func takeCaretAtEnd() -> Bool {
    defer { caretAtEnd = false }
    return caretAtEnd
  }

  @ObservationIgnored private var caretAtEnd = false

  /// 地図の器のキー。サブメニューを開いている間はそちらへ回す。↑↓・⌘↵（部品の段。`BoardAutomationHand.stroke` に任せる）・
  /// ↵ / →（「通知」の段）・← / esc のほかは何も起こさず、どれも握る（焦点をボードの外へ逃がさない）。
  func handleMapKey(_ press: KeyPress) -> KeyPress.Result {
    if let cursor = notifyCursor {
      handleNotifyKey(press, cursor)
    } else if let stroke = BoardAutomationHand.stroke(press, at: .map) {
      if case .press(let operation) = stroke { perform(operation) }
    } else if press.key == .return || press.key == .rightArrow,
      press.modifiers.isDisjoint(with: Self.chords)
    {
      if press.phase == .down, selectedMapStop == .notify { openNotify() }
    } else if press.key == .leftArrow || press.key == .escape,
      press.modifiers.isDisjoint(with: Self.chords)
    {
      if press.phase == .down { leaveMap() }
    } else if press.key == .upArrow || press.key == .downArrow,
      !press.modifiers.contains(.command)
    {
      moveInMap(press.key == .upArrow ? -1 : 1)
    }
    return .handled
  }

  /// 一覧の器のキー。↑↓・↵ / →（地図へ）・`BoardAutomationHand.stroke` に任せるキーのほかは何も起こさず、どれも握る（⇥ で
  /// 焦点をボードの外へ逃がさない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if let stroke = BoardAutomationHand.stroke(press, at: .list) {
      if case .press(let operation) = stroke { perform(operation) }
    } else if press.key == .return || press.key == .rightArrow,
      press.modifiers.isDisjoint(with: Self.chords)
    {
      if press.phase == .down { enterMap() }
    } else if press.key == .upArrow || press.key == .downArrow,
      !press.modifiers.contains(.command)
    {
      move(press.key == .upArrow ? -1 : 1)
    }
    return .handled
  }

  // MARK: - 通知

  /// サブメニューを開く。選んでいる行は今の設定から。
  func openNotify() {
    guard let automation = selectedAutomation, selectedMapStop == .notify else { return }
    onRefusal(nil)
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
    _ = try? runner.set(automation.id, version: automation.version, definition)
    reconcile()
  }

  /// サブメニューのキー。↑↓ は端で巡回し、↵ で決め、← / esc で何もせず閉じて「通知」の段へ。ほかは下の操作を起こさずに
  /// 握る。
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
