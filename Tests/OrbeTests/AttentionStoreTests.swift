import XCTest

@testable import Orbe

/// `AttentionStore` 自身が持つ不変条件——**②ピルは一覧（`listRows`）の投影である**——を固定する。
/// 行 snapshot を差し替える唯一の入口 `apply(rows:)` が、投影元を失ったピルを取り下げる。
@MainActor
final class AttentionStoreTests: XCTestCase {

  private func row(paneId: Int, state: String, message: String? = nil) -> AttentionRow {
    AttentionRow(
      paneId: paneId, workspaceName: "ws", tabTitle: "tab", state: state, message: message,
      stateChangedAt: Date())
  }

  /// 同じ paneId・同じ状態で一覧に居る限りピルは残り、行の中身が変わっても差し替えない
  /// （立て直すのは report 経路の仕事）。
  func testTransientSurvivesWhileProjected() {
    let store = AttentionStore()
    store.apply(rows: [row(paneId: 1, state: "waiting", message: "q")])
    store.noteTransient(row(paneId: 1, state: "waiting", message: "q"))
    store.apply(rows: [row(paneId: 1, state: "waiting", message: "別の文言")])
    XCTAssertEqual(store.transient?.row.paneId, 1)
    XCTAssertEqual(store.transient?.row.message, "q", "行が残っている間の中身は更新しない")
  }

  /// 同じペインでも状態が変われば取り下げる——判定は `paneId` だけでなく `state` も見る。
  ///
  /// これは**契約そのもの**（「②が指す行が同じ paneId かつ同じ state で一覧に居ること」）を
  /// 固定する。現状 `state` だけが食い違う到達経路は無い——report 経路は waiting/done の実変化の
  /// たびに②を新しい行で立て直し、それが抑制される「見ているタブ」では done が idle へ消費されて
  /// 行ごと消えるため。将来 `state` 条件を落とす変更をここで捕まえる。
  func testTransientWithdrawnWhenSamePaneChangesState() {
    let store = AttentionStore()
    store.noteTransient(row(paneId: 1, state: "waiting"))
    store.apply(rows: [row(paneId: 1, state: "done")])
    XCTAssertNil(store.transient)
  }

  /// `working` は一覧（`listRows`）に含まれないので、`working` へ戻ったペインのピルは取り下がる。
  ///
  /// 判定が `listRows` を見るのは「②は一覧の投影」という契約の直の表現。現状は `state` 一致も
  /// 見ており transient の状態は必ず waiting/done なので、`rows` に替えても振る舞いは変わらない
  /// （実測で全緑）。`listRows` は `state` 条件が将来緩んだときに独立して効く歯止めとして残す。
  func testTransientWithdrawnWhenPaneReturnsToWorking() {
    let store = AttentionStore()
    store.noteTransient(row(paneId: 1, state: "waiting"))
    store.apply(rows: [row(paneId: 1, state: "working")])
    XCTAssertNil(store.transient)
  }

  /// 行そのものが消えれば（idle / clear / 閉じられた）取り下げる。
  func testTransientWithdrawnWhenRowGone() {
    let store = AttentionStore()
    store.noteTransient(row(paneId: 1, state: "waiting"))
    store.apply(rows: [])
    XCTAssertNil(store.transient)
  }

  /// 別ペインの行が入れ替わってもピルは残る。
  func testTransientSurvivesUnrelatedRowChange() {
    let store = AttentionStore()
    store.noteTransient(row(paneId: 1, state: "waiting"))
    store.apply(rows: [row(paneId: 1, state: "waiting"), row(paneId: 2, state: "done")])
    XCTAssertEqual(store.transient?.row.paneId, 1)
    store.apply(rows: [row(paneId: 1, state: "waiting")])
    XCTAssertEqual(store.transient?.row.paneId, 1)
  }
}
