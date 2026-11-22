import AppKit
import XCTest

@testable import Orbe

/// Orbe が前面に戻ったときの引き直し——見ている者がいる worktree の今の PR だけが、今のブランチの PR を 1 回引き直す。
/// PR が無いままなら答えも作成の入口の材料も替えず、ブランチが GitHub に在るかは問い合わせない。ブラウザで作られた PR は、
/// 前面に戻れば答えに出る。前面化は通知を手で出す（アプリを前面化しない）。
///
/// 壊れると何が起きるか: ブラウザで PR を作って Orbe に戻っても「プルリクエストなし」のまま。前面に戻るたびに在るかの
/// 問い合わせが重なり、作成のボタンの姿がちらつく。エディターを閉じていても GitHub に問い合わせる。
extension BranchPullRequestTests {
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
    letTheLookUpSettle()
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
    letTheLookUpSettle()
    XCTAssertEqual(lookups.count, 2, "誰も見ていなければ問い合わせない")
  }

  private func becomeActive() {
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
  }

  private func isPublished(_ pullRequest: BranchPullRequest) -> Bool {
    if case .noPullRequest(let creation) = pullRequest.answer { return creation.published == .yes }
    return false
  }
}
