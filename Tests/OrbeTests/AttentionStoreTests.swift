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
  /// waiting → done は一覧に残ったまま状態だけが変わるので、`state` の一致を外すとここで落ちる。
  /// `working` へ戻った場合も同じ判定で取り下がる（`working` は一覧にも居ない）。
  func testTransientWithdrawnWhenSameTabChangesState() {
    let store = AttentionStore()
    store.noteTransient(row(tabId: 1, state: "waiting"), dwell: anyDwell)
    store.apply(rows: [row(tabId: 1, state: "done")])
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
