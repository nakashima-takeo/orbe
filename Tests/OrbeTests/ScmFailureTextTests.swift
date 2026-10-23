import XCTest

@testable import Orbe

/// 失敗の文——ブランチに居ない断りは、断った操作を言う。
///
/// 壊れると何が起きるか。detached HEAD の初回コミットの取り消しを断ったのに、「プル・プッシュできません」と出て、何が
/// できなかったのか読み違える。
final class ScmFailureTextTests: OrbeTestCase {
  func testTheDetachedRefusalSaysWhichOperationWasRefused() {
    func text(_ kind: SourceControl.Kind) -> String? {
      ScmFailureText.text(SourceControl.Failure(kind: kind, cause: .git(.detached)), .en)
    }
    XCTAssertEqual(text(.undo), L10n.string(.editorScmFailureUndoDetached, .en))
    for kind in [.pull, .push, .sync] as [SourceControl.Kind] {
      XCTAssertEqual(text(kind), L10n.string(.editorScmFailureDetached, .en), "\(kind)")
    }
  }
}
