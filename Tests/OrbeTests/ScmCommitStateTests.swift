import XCTest

@testable import Orbe

/// コミットボタンと ▾ の姿。
///
/// 壊れると何が起きるか。変更があるのにボタンが同期に替わって押すとネット操作が走る・upstream の無いブランチで公開が
/// 出ない・push 済みのコミットを amend で書き換えられる（Orbe の中では戻せない）・push 済みか分からない間に取り消せる・
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
      staged: staged, changes: changes, committable: committable ?? changes, branch: branch,
      messageIsBlank: blank,
      isNetworking: networking, isCommitting: committing, isHeadPushed: pushed)
  }

  /// 変更が 1 つでもあればコミット。押せるのはステージ済みかコミットに入る変更（競合と中身だけ変わったサブモジュールを
  /// 除く）があり、メッセージが空白だけでなく、コミット中でないとき。
  func testCommitNeedsCommittableChangesAndAMessage() {
    let tracked = branch(upstream: upstream(ahead: 2, behind: 0))
    XCTAssertEqual(state(changes: 1, branch: tracked, blank: false).primary, .commit)
    XCTAssertTrue(state(changes: 1, branch: tracked, blank: false).isButtonEnabled)
    XCTAssertFalse(state(changes: 1, committable: 0, branch: tracked, blank: false).canCommit)
    XCTAssertFalse(state(staged: 1, branch: tracked).canCommit)
    XCTAssertTrue(state(staged: 1, branch: tracked, blank: false).canCommit)
    XCTAssertFalse(state(staged: 1, branch: tracked, blank: false, committing: true).canCommit)
    XCTAssertTrue(state(staged: 1, branch: tracked, blank: false, networking: true).canCommit)
    XCTAssertFalse(
      state(staged: 1, branch: tracked, blank: false, networking: true).canCommitAndPush)
  }

  /// 変更が無ければ、先行/遅れのある upstream で同期、upstream の無いブランチで公開。ネット操作中は押せず、⌘↵ の
  /// コミットはどちらでも起きない。
  func testSyncAndPublishReplaceTheButtonOnlyWithoutChanges() {
    let ahead = state(branch: branch(upstream: upstream(ahead: 2, behind: 1)))
    XCTAssertEqual(ahead.primary, .sync(GitStatus.Divergence(ahead: 2, behind: 1)))
    XCTAssertTrue(ahead.isButtonEnabled)
    XCTAssertFalse(ahead.canCommit)
    XCTAssertFalse(
      state(branch: branch(upstream: upstream(ahead: 2, behind: 0)), networking: true)
        .isButtonEnabled)
    XCTAssertEqual(state(branch: branch(upstream: upstream(ahead: 0, behind: 0))).primary, .commit)
    XCTAssertEqual(state(branch: branch()).primary, .publish)
    XCTAssertEqual(state(branch: branch(name: nil)).primary, .commit)
    XCTAssertEqual(state(branch: branch(commit: nil)).primary, .commit)
    let unknown = GitStatus.Upstream(name: "origin/feat", divergence: nil)
    XCTAssertEqual(state(branch: branch(upstream: unknown)).primary, .commit)
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
