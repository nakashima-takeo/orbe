import XCTest

@testable import Orbe

/// 秘書のタブの閉じ方と、休眠の秘書のタブの見つけ方。
///
/// 壊れると何が起きるか: 人が閉じた秘書の会話が捨てられ、頼んでいない新しい秘書が起きる。手で開いた同じ会話のタブが
/// あると、休眠の秘書のタブを起こさず 3 本目を開く。
extension SecretaryTests {
  /// 覚えた会話で起こしたタブを、会話を報告する前に人が閉じても、その会話は捨てず、勝手に起こし直さない。
  func testAResumedSecretaryClosedByThePersonBeforeItsFirstReportKeepsItsConversation() throws {
    let wc = try launch(SecretaryFile(version: 1, sessionId: "s-1", pending: []))
    _ = try wc.secretary.ask(.text("届けたい"))
    let resumed = try XCTUnwrap(try homeTabs(wc).first)

    wc.closeTab(resumed, origin: .gesture)
    wc.flushChrome()

    XCTAssertEqual(wc.secretary.record.sessionId, "s-1", "人が閉じた会話は捨てない")
    XCTAssertFalse(waitUntil(1) { !((try? self.homeTabs(wc)) ?? []).isEmpty }, "勝手に起こし直さない")
    XCTAssertEqual(wc.secretary.record.pending.count, 1, "溜めは残る")
  }

  /// 人が同じ会話を手で開いて動かしていても、頼むと休眠の秘書のタブを起こす（もう 1 本開かない）。
  func testTheDormantSecretaryWakesEvenWhileTheUserRunsItsConversationByHand() throws {
    let wc = try launch(
      SecretaryFile(version: 1, sessionId: "s-1", pending: []),
      homeTabs: [
        TabState(
          cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "s-1"),
          explicitTitle: nil),
        TabState(cwd: "/tmp", agent: nil, explicitTitle: nil),
      ])
    let (dormant, byHand) = (try homeTabs(wc)[0], try homeTabs(wc)[1])
    wc.wakeUnselected(byHand)
    report(wc, byHand, "idle", "s-1")

    _ = try wc.secretary.ask(.text("休眠のタブへ"))

    XCTAssertEqual(try homeTabs(wc).count, 2, "もう 1 本開かない")
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) { !dormant.isDormant }, "休眠の秘書のタブを起こす")
    XCTAssertEqual(wc.secretary.tabId, dormant.id)
  }
}
