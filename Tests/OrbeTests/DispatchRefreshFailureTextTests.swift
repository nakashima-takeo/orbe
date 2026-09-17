import XCTest

@testable import Orbe

/// 最新化が落ちたときに画面が名乗る「どの段で・なぜ」の導出（モデルは事実だけを持ち、文言はここが作る）。
///
/// ここが破れると、失敗画面が原因を取り違えて名乗る——remote へ届かなかったのか、手元が分岐していて
/// 進めないのか、checkout 中で git に拒まれたのかが読めなくなり、次に何をすればよいか分からなくなる。
@MainActor
final class DispatchRefreshFailureTextTests: OrbeTestCase {
  private let l10n = LocalizationStore(language: .ja)
  private let upstream = GitUpstream(
    short: "origin/stale", ref: "refs/remotes/origin/stale", remote: "origin",
    remoteRef: "refs/heads/stale", track: .counts(ahead: 0, behind: 3))

  /// 落ちた段は git の語のまま名乗る（✕ ピルと行の説明が同じ語を使う）。
  func testStepNamesTheGitCommandThatFailed() {
    XCTAssertEqual(DispatchRefreshFailureText.step(.fetch(.timedOut)), "fetch")
    XCTAssertEqual(DispatchRefreshFailureText.step(.fetch(.reason("fatal: boom"))), "fetch")
    XCTAssertEqual(DispatchRefreshFailureText.step(.fastForward(nil)), "fast-forward")
    XCTAssertEqual(DispatchRefreshFailureText.step(.fastForward(.timedOut)), "fast-forward")
  }

  /// 理由は git が言い残した実質行をそのまま出し、git が黙る 2 つ（打ち切り・分岐）だけ chrome の文にする。
  func testReasonQuotesGitAndSpeaksOnlyWhereGitIsSilent() {
    XCTAssertEqual(
      reason(.fetch(.reason("fatal: unable to access 'origin'"))),
      "fatal: unable to access 'origin'")
    XCTAssertEqual(
      reason(.fastForward(.reason("fatal: 'stale' is already checked out"))),
      "fatal: 'stale' is already checked out")
    XCTAssertEqual(reason(.fetch(.timedOut)), l10n.string(.gitTimedOut))
    XCTAssertEqual(reason(.fastForward(.timedOut)), l10n.string(.gitTimedOut))
    XCTAssertEqual(
      reason(.fastForward(nil)), "origin/stale と分岐", "分岐のとき git は黙るので Orbe が upstream を名指す")
  }

  private func reason(_ failure: GitRefreshFailure) -> String {
    DispatchRefreshFailureText.reason(failure, upstream: upstream, l10n)
  }
}
