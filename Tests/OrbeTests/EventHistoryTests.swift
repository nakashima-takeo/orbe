import XCTest

@testable import Orbe

/// `EventHistory`（制御イベントのリングバッファと seq 発番）の境界を固定する。
///
/// 壊れると何が起きるか: `wait_for_event {after}` の replay がずれる。保持範囲の判定が 1 つ甘ければ
/// 「落ちた seq」を `.none` と答えて待機を張り、既に起きた遷移を永遠に待つ（`orb wait --after` が
/// 取りこぼしを直すために在るのに、その取りこぼしが戻る）。逆に厳しければ、まだ保持している seq を
/// `-32006` で拒み、呼び出し側は seq を取り直す羽目になる。seq が 1 本の単調増加でなくなれば
/// 「これより大きい seq はこの操作より後」という応答の `seq` の意味が崩れる。
final class EventHistoryTests: OrbeTestCase {
  private func stateEvent(_ tabId: Int, _ state: String) -> ControlEvent {
    .agentState(tabId: tabId, state: state, message: nil, sessionId: nil)
  }

  private func matchedSeq(_ replay: EventHistory.Replay) -> Int? {
    if case .match(let record) = replay { return record.seq }
    return nil
  }

  // MARK: - seq

  /// seq は kind・tab を問わず 1 本で、1 始まりの単調増加。
  func testSeqIsOneMonotonicCounterAcrossKindsAndTabs() {
    var history = EventHistory(capacity: 8)
    XCTAssertEqual(history.latestSeq, 0, "イベント未発生なら 0")

    let seqs = [
      history.append(stateEvent(1, "working")),
      history.append(.title(tabId: 2, title: "t")),
      history.append(.pwd(tabId: 3, path: "/p")),
      history.append(.tabClosed(tabId: 1)),
    ].map(\.seq)

    XCTAssertEqual(seqs, [1, 2, 3, 4], "kind と tab を跨いで 1 本の seq が 1 から振られる")
    XCTAssertEqual(history.latestSeq, 4, "latestSeq は最後に振った seq")
  }

  // MARK: - replay の境界

  /// 空の履歴では `after: 0` だけが「一致なし（待つ）」で、それより大きい `after` は未来。
  func testEmptyHistoryOnlyAcceptsAfterZero() {
    let history = EventHistory(capacity: 8)

    guard case .none = history.replay(after: 0, where: { _ in true }) else {
      return XCTFail("空の履歴で after 0 は .none（待機を張る）")
    }
    guard case .future = history.replay(after: 1, where: { _ in true }) else {
      return XCTFail("空の履歴で after 1 は .future（観測しえない seq）")
    }
  }

  /// `after` が最新 seq と同じなら一致なし、最新より大きければ未来。
  func testAfterAtOrBeyondLatestSeq() {
    var history = EventHistory(capacity: 8)
    _ = history.append(stateEvent(1, "done"))
    _ = history.append(stateEvent(1, "idle"))

    guard case .none = history.replay(after: 2, where: { _ in true }) else {
      return XCTFail("after == latestSeq は .none（全件が after 以前）")
    }
    guard case .future = history.replay(after: 3, where: { _ in true }) else {
      return XCTFail("after > latestSeq は .future")
    }
  }

  /// `after` より後の中で、seq 昇順に**最初の**一致を返す（最新の一致ではない）。
  func testReplayReturnsTheFirstMatchAfterTheCursorInSeqOrder() {
    var history = EventHistory(capacity: 8)
    _ = history.append(stateEvent(1, "done"))  // seq 1: after 以前なので対象外
    _ = history.append(stateEvent(1, "working"))  // seq 2: 一致しない
    _ = history.append(stateEvent(1, "done"))  // seq 3: 最初の一致
    _ = history.append(stateEvent(1, "done"))  // seq 4: 後の一致

    let replay = history.replay(after: 1) { $0.value == "done" }

    XCTAssertEqual(matchedSeq(replay), 3, "after より後で最初に一致した record を返す")
  }

  /// `after` より後に一致が無ければ待つ側へ倒す（after 以前の一致は数えない）。
  func testNoMatchAfterTheCursorIsNone() {
    var history = EventHistory(capacity: 8)
    _ = history.append(stateEvent(1, "done"))
    _ = history.append(stateEvent(1, "working"))

    guard case .none = history.replay(after: 1, where: { $0.value == "done" }) else {
      return XCTFail("after 以前の一致は数えず .none")
    }
  }

  // MARK: - 保持範囲

  /// 容量を超えると最古から落ち、seq `after + 1` が落ちていれば evicted。
  /// 落ちていないぎりぎり（`after + 1` が最古）は普通に replay できる。
  func testEvictionBoundaryIsExactlyWhereAfterPlusOneHasBeenDropped() {
    var history = EventHistory(capacity: 3)
    for _ in 1...5 { _ = history.append(stateEvent(1, "done")) }  // 保持は seq 3, 4, 5

    XCTAssertEqual(
      matchedSeq(history.replay(after: 2, where: { _ in true })), 3,
      "after + 1 が最古の record なら replay できる（境界の内側）")
    guard case .evicted = history.replay(after: 1, where: { _ in true }) else {
      return XCTFail("seq 2 は既に落ちているので after 1 は .evicted")
    }
    guard case .evicted = history.replay(after: 0, where: { _ in true }) else {
      return XCTFail("after 0 も保持範囲より古い")
    }
  }

  /// リングが一周した後も走査は seq 昇順（配列の物理順ではない）。
  func testReplayWalksInSeqOrderAfterTheRingWrapsAround() {
    var history = EventHistory(capacity: 3)
    _ = history.append(stateEvent(1, "a"))  // seq 1（落ちる）
    _ = history.append(stateEvent(1, "b"))  // seq 2 → 物理 index 1
    _ = history.append(stateEvent(1, "c"))  // seq 3 → 物理 index 2
    _ = history.append(stateEvent(1, "b"))  // seq 4 → 物理 index 0（上書き）

    let replay = history.replay(after: 1) { $0.value == "b" }

    XCTAssertEqual(matchedSeq(replay), 2, "物理順なら seq 4 が先に見えるが、seq 昇順で seq 2 を返す")
  }

  /// 容量ちょうどまでは何も落ちない（満杯そのものは evicted ではない）。
  func testFullRingWithoutOverflowRetainsEverything() {
    var history = EventHistory(capacity: 3)
    for _ in 1...3 { _ = history.append(stateEvent(1, "done")) }

    XCTAssertEqual(
      matchedSeq(history.replay(after: 0, where: { _ in true })), 1, "満杯でも seq 1 は保持されている")
  }
}
