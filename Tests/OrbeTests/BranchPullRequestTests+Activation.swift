import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// Orbe が前面に戻ったときの引き直し——見ている者がいる worktree の今の PR だけが、今のブランチの PR を 1 回引き直す。
/// PR が無いままなら答えも作成の入口の材料も替えず、ブランチが GitHub に在るかは問い合わせない。ブラウザで作られた PR は、
/// 前面に戻れば答えに出る。前面化は通知を手で出す（アプリを前面化しない）。
///
/// 壊れると何が起きるか: ブラウザで PR を作って Orbe に戻っても「プルリクエストなし」のまま。前面に戻るたびに在るかの
/// 問い合わせが重なり、作成のボタンの姿がちらつく。エディターを閉じていても GitHub に問い合わせる。
extension BranchPullRequestTests {
  /// 在るかを問い合わせ直さないことは、引き直しの答えが届いた時点で、待たずに確かめる。前提は、差し替えの出どころが
  /// 問い合わせの中で同期に答え、答えを受けた処理が、在るかを問い合わせるかをその場で決めること。前面に戻ったときに材料を
  /// 古くするようにすると、このテストが落ちることを確かめてある。答えを受けてから在るかを問い合わせるまでの経路を変えたときは、
  /// 確かめ直す。
  func testBecomingActiveLooksUpThePullRequestOnceWithoutCheckingThePublishedStateAgain() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    let ref = GitHubBranchRef(repo: me, branch: "feat")
    answers["feat"] = .gitHub(ref, pullRequests: .success([]))
    let pullRequest = watch()
    pumpMain(until: { self.isPublished(pullRequest) }, "前提: PR が無く、ブランチは GitHub に在る")
    XCTAssertEqual(lookups.count, 1)
    XCTAssertEqual(publishedChecks.count, 1)

    becomeActive()
    pumpMain(until: { self.lookups.count == 2 }, "前面に戻れば今のブランチの PR を引き直す")
    XCTAssertEqual(publishedChecks.count, 1, "PR が無いままなら、在るかを問い合わせ直さない")
    XCTAssertTrue(isPublished(pullRequest), "作成の入口の姿は動かない")

    answers["feat"] = .gitHub(ref, pullRequests: .success([pr(7, state: "OPEN")]))
    becomeActive()
    pumpMain(until: { pullRequest.state?.key.id.number == 7 }, "ブラウザで作った PR が答えに出る")
  }

  /// どの PR かだけを追う者しかいなくても前面に戻れば引き直し、誰も見ていなければ問い合わせない。
  func testBecomingActiveAsksOnlyWhileSomeoneTracks() {
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    answers["feat"] = .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([]))
    let pullRequest = BranchPullRequest.shared(for: repo.root, source: source)
    pullRequest.beginTracking()
    settled(pullRequest)
    becomeActive()
    pumpMain(until: { self.lookups.count == 2 }, "追っている間は引き直す")
    XCTAssertEqual(publishedChecks, [], "中身を読む者がいなければ、在るかを問い合わせない")

    pullRequest.endTracking()
    becomeActive()
    XCTAssertTrue(holds(for: 1) { self.lookups.count == 2 }, "誰も見ていなければ問い合わせない")
  }

  private func becomeActive() {
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
  }

  private func isPublished(_ pullRequest: BranchPullRequest) -> Bool {
    if case .noPullRequest(let creation) = pullRequest.answer { return creation.published == .yes }
    return false
  }
}
