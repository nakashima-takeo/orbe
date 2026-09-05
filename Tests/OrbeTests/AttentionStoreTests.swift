import XCTest

@testable import Orbe

/// `AttentionStore` 自身が持つ不変条件——**②ピルは一覧（`listRows`）の投影である**——を固定する。
/// 行 snapshot を差し替える唯一の入口 `apply(rows:)` が、投影元を失ったピルを取り下げる。
/// 取り下げは `retracted` を立てるだけで `transient` は残す——収縮を描き切るための中身で、
/// 落とすのは閉じ切った `MenuBarController`（②が消える見え方を収縮 1 つに保つ）。
@MainActor
final class AttentionStoreTests: OrbeTestCase {

  /// 取り下げの検証は滞留を見ない（見るのは `retracted`）。必須引数の値をここ 1 箇所に閉じる。
  private let anyDwell: TimeInterval = 7

  private func row(tabId: Int, state: String, message: String? = nil) -> AttentionRow {
    AttentionRow(
      tabId: tabId, workspaceName: "ws", tabTitle: "tab", state: state, message: message,
      stateChangedAt: Date())
  }

  /// 到来時刻と滞留の満了時刻。`expiresAt` は収縮の開始時刻で、②の総寿命はここから 600ms 先。
  /// `arrivedAt` は「新しい到来か」を MenuBarController が見分ける印なので、到来時刻そのもの。
  /// 滞留は store が既定を持たず、渡された `dwell` がそのまま `expiresAt` に焼かれる。
  func testNoteTransientStampsArrivalAndDwell() {
    let store = AttentionStore()
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: 75, now: now)
    XCTAssertEqual(store.transient?.arrivedAt, now)
    XCTAssertEqual(store.transient?.expiresAt, now.addingTimeInterval(75))
  }

  /// 同じ tabId・同じ状態で一覧に居る限りピルは残り、行の中身が変わっても差し替えない
  /// （立て直すのは report 経路の仕事）。
  func testTransientSurvivesWhileProjected() {
    let store = AttentionStore()
    store.apply(rows: [row(tabId: 1, state: "waiting", message: "q")])
    store.noteTransient(row(tabId: 1, state: "waiting", message: "q"), dwell: anyDwell)
    store.apply(rows: [row(tabId: 1, state: "waiting", message: "別の文言")])
    XCTAssertEqual(store.transient?.row.tabId, 1)
    XCTAssertEqual(store.transient?.row.message, "q", "行が残っている間の中身は更新しない")
  }

  /// 同じタブでも状態が変われば取り下げる——判定は `tabId` だけでなく `state` も見る。
  ///
  /// これは**契約そのもの**（「②が指す行が同じ tabId かつ同じ state で一覧に居ること」）を
  /// 固定する。現状 `state` だけが食い違う到達経路は無い——report 経路は waiting/done の実変化の
  /// たびに②を新しい行で立て直し、それが抑制される「見ているタブ」では done が idle へ消費されて
  /// 行ごと消えるため。将来 `state` 条件を落とす変更をここで捕まえる。
  func testTransientWithdrawnWhenSameTabChangesState() {
    let store = AttentionStore()
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: anyDwell)
    store.apply(rows: [row(tabId: 1, state: "done")])
    XCTAssertEqual(store.transient?.retracted, true)
  }

  /// `working` は一覧（`listRows`）に含まれないので、`working` へ戻ったタブのピルは取り下がる。
  ///
  /// 判定が `listRows` を見るのは「②は一覧の投影」という契約の直の表現。現状は `state` 一致も
  /// 見ており transient の状態は必ず waiting/done なので、`rows` に替えても振る舞いは変わらない
  /// （実測で全緑）。`listRows` は `state` 条件が将来緩んだときに独立して効く歯止めとして残す。
  func testTransientWithdrawnWhenTabReturnsToWorking() {
    let store = AttentionStore()
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: anyDwell)
    store.apply(rows: [row(tabId: 1, state: "working")])
    XCTAssertEqual(store.transient?.retracted, true)
  }

  /// 行そのものが消えれば（idle / clear / 閉じられた）取り下げる。中身は収縮のために残る。
  func testTransientWithdrawnWhenRowGone() {
    let store = AttentionStore()
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: anyDwell)
    store.apply(rows: [])
    XCTAssertEqual(store.transient?.retracted, true)
    XCTAssertEqual(store.transient?.row.tabId, 1, "収縮を描き切るまで中身は残る")
  }

  /// 取り下げは一度きり。閉じている間に一覧が何度差し替わっても印は立ち続け、判定を蒸し返さない
  /// （取り下げ後に行が戻っても、閉じかけのピルを開き直しはしない——立て直すのは report 経路）。
  func testRetractionIsStickyAcrossFurtherApplies() {
    let store = AttentionStore()
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: anyDwell)
    store.apply(rows: [])
    store.apply(rows: [row(tabId: 1, state: "waiting")])
    XCTAssertEqual(store.transient?.retracted, true)
  }

  /// 別タブの行が入れ替わってもピルは残る。
  func testTransientSurvivesUnrelatedRowChange() {
    let store = AttentionStore()
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: anyDwell)
    store.apply(rows: [row(tabId: 1, state: "waiting"), row(tabId: 2, state: "done")])
    XCTAssertEqual(store.transient?.row.tabId, 1)
    store.apply(rows: [row(tabId: 1, state: "waiting")])
    XCTAssertEqual(store.transient?.row.tabId, 1)
  }
}
