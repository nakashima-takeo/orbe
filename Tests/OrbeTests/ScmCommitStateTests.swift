import XCTest

@testable import Orbe

/// コミットと ▾ の項目の可否と、同期のボタンの姿。
///
/// 壊れると何が起きるか。upstream の無いブランチで公開が出ない・detached HEAD で同期が出て押すと断られる・ネット操作の
/// 最中に同期が押せる・push 済みのコミットを amend で書き換えられる（Orbe の中では戻せない）・push 済みか分からない間に取り消せる・
/// push と並んで amend・取り消しが走り、push したコミットを書き換える・競合だけなのにコミットが押せる。
final class ScmCommitStateTests: OrbeTestCase {
  private func branch(
    name: String? = "feat", commit: String? = "abc", upstream: GitStatus.Upstream? = nil
  ) -> GitStatus.Branch {
    GitStatus.Branch(name: name, commit: commit, upstream: upstream)
  }

  private func upstream(ahead: Int, behind: Int) -> GitStatus.Upstream {
    GitStatus.Upstream(
      name: "origin/feat", divergence: GitStatus.Divergence(ahead: ahead, behind: behind))
  }

  private func state(
    staged: Int = 0, changes: Int = 0, committable: Int? = nil, branch: GitStatus.Branch?,
    blank: Bool = true, networking: Bool = false, committing: Bool = false, pushed: Bool? = false
  ) -> ScmCommitState {
    ScmCommitState(
      staged: staged, committable: committable ?? changes, branch: branch, messageIsBlank: blank,
      isNetworking: networking, isCommitting: committing, isHeadPushed: pushed)
  }

  /// コミットが押せるのは、ステージ済みかコミットに入る変更（競合と中身だけ変わったサブモジュールを除く）があり、
  /// メッセージが空白だけでなく、コミット中でないとき。
  func testCommitNeedsCommittableChangesAndAMessage() {
    let tracked = branch(upstream: upstream(ahead: 2, behind: 0))
    XCTAssertTrue(state(changes: 1, branch: tracked, blank: false).canCommit)
    XCTAssertFalse(state(changes: 1, committable: 0, branch: tracked, blank: false).canCommit)
    XCTAssertFalse(state(staged: 1, branch: tracked).canCommit)
    XCTAssertTrue(state(staged: 1, branch: tracked, blank: false).canCommit)
    XCTAssertFalse(state(staged: 1, branch: tracked, blank: false, committing: true).canCommit)
    XCTAssertTrue(state(staged: 1, branch: tracked, blank: false, networking: true).canCommit)
    XCTAssertFalse(
      state(staged: 1, branch: tracked, blank: false, networking: true).canCommitAndPush)
  }

  /// 同期のボタンは、upstream の在るブランチで同期（先行・遅れが分かり、和が 1 以上なら数つき）、コミットが在り upstream の
  /// 無いブランチで公開。upstream の ref が手元に無いブランチでは、同期の姿で押せない。detached HEAD・初回コミットの前・
  /// ブランチが分からない間は出さない。ネット操作中は押せない。
  func testSyncAndPublishFollowTheBranch() {
    func sync(_ branch: GitStatus.Branch?, networking: Bool = false) -> ScmSyncState? {
      ScmSyncState(branch: branch, isNetworking: networking)
    }
    let ahead = sync(branch(upstream: upstream(ahead: 2, behind: 1)))
    XCTAssertEqual(ahead?.action, .sync(GitStatus.Divergence(ahead: 2, behind: 1)))
    XCTAssertEqual(ahead?.isEnabled, true)
    XCTAssertEqual(
      sync(branch(upstream: upstream(ahead: 2, behind: 0)), networking: true)?.isEnabled, false)
    XCTAssertEqual(sync(branch(upstream: upstream(ahead: 0, behind: 0)))?.action, .sync(nil))
    let gone = GitStatus.Upstream(name: "origin/feat", divergence: nil)
    XCTAssertEqual(sync(branch(upstream: gone))?.action, .upstreamGone("origin/feat"))
    XCTAssertEqual(sync(branch(upstream: gone))?.isEnabled, false)
    XCTAssertEqual(sync(branch())?.action, .publish)
    XCTAssertNil(sync(branch(name: nil)))
    XCTAssertNil(sync(branch(commit: nil)))
    XCTAssertNil(sync(nil))
  }

  /// HEAD が push 済み・分からない・初回コミット前、コミット中・ネット操作中なら amend と取り消しは押せない。
  func testRewritingNeedsAnUnpushedHead() {
    let head = branch()
    XCTAssertTrue(state(staged: 1, branch: head).canAmend)
    XCTAssertTrue(state(branch: head).canUndo)
    XCTAssertFalse(state(branch: head, blank: true).canAmend)
    XCTAssertTrue(state(changes: 1, branch: head).canAmend, "ステージ済みが無ければ変更の全部を入れる")
    XCTAssertFalse(state(changes: 1, committable: 0, branch: head).canAmend, "競合だけでは入れるものが無い")
    for pushed in [true, nil] as [Bool?] {
      XCTAssertFalse(state(staged: 1, branch: head, pushed: pushed).canAmend)
      XCTAssertFalse(state(branch: head, pushed: pushed).canUndo)
    }
    XCTAssertFalse(state(branch: branch(commit: nil)).canUndo)
    XCTAssertFalse(state(branch: head, committing: true).canUndo)
    XCTAssertFalse(state(staged: 1, branch: head, networking: true).canAmend)
    XCTAssertFalse(state(branch: head, networking: true).canUndo)
  }
}
