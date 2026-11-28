import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 揃える読みをやめた間の diff のスレッドの絵——置けないと決まったスレッドの絵は外し、返信の書きかけの在る欄は残す。外した欄に
/// 焦点が在れば、焦点は diff の本文へ移る。再読込で揃えば絵は戻り、見えている先頭の行は動かない。PR の中身とレビューのやりとりは
/// 差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 一覧で置けないとされたスレッドの絵が diff に残る。打ちかけの返信の欄が消える。外した欄に焦点が残って、
/// 打った字がどこにも入らない。揃って絵が戻ると、読んでいた行から画面が跳ぶ。
extension EditorDiffTests {
  /// 行 120・150・160 のスレッドのうち、行 150 の空の返信欄に焦点を置き、行 160 の返信欄に書きかけを置いて、行 120 のスレッドより
  /// 下を読んでいる間に、揃える読みをやめる。書きかけの無い 2 つの絵は外れ、焦点は本文へ移り、書きかけの欄は残る。揃うと 3 つとも
  /// 戻り、先頭に見えている行は読んでいた行のまま。
  func testThreadsLeaveWhileReadsStopAndComeBackWithoutMovingTheView() throws {
    var lines = (1...200).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    remote.threads = [
      stoppedThread("T_above", line: 120), stoppedThread("T_empty", line: 150),
      stoppedThread("T_draft", line: 160),
    ]
    let opened = try commentedTab(remote) {
      lines[2] = "THREE"
      try self.repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    }
    opened.tab.group.view.editor.reviewPopup.onOpenURL = { XCTFail("ブラウザを開かない: \($0)") }
    let state = try XCTUnwrap(opened.tab.group.view.editor.pullRequest.state)
    let diff = opened.diff
    let surface = try engine(diff.newSurface)
    let window = try XCTUnwrap(surface.textView.window)
    let shown = { () -> Set<String> in
      surface.flush()
      return Set(
        ["T_above", "T_empty", "T_draft"].filter { id in
          diff.comments?.zone(thread: id).flatMap {
            surface.rows.block(ofZone: ObjectIdentifier($0))
          }
            != nil
        })
    }
    pumpMain(until: { shown() == ["T_above", "T_empty", "T_draft"] }, "前提: スレッドが置かれる")
    let empty = try XCTUnwrap(diff.comments?.zone(thread: "T_empty"))
    let draft = try XCTUnwrap(diff.comments?.zone(thread: "T_draft"))
    window.makeFirstResponder(surface.textView)
    surface.focus(draft.field)
    surface.replaceText(of: draft.field, with: "書きかけ")
    surface.focus(empty.field)
    surface.scroll(toFirstLine: 140)
    surface.flush()
    let top = surface.rows.item(atY: surface.scrollPosition.y)
    XCTAssertEqual(surface.primary, .field(empty.field.id), "前提: 空の返信欄に焦点")

    let head = remote.head
    remote.head = String(repeating: "0", count: 40)
    state.reload()
    pumpMain(until: { state.stoppedAligning && shown() == ["T_draft"] }, "書きかけの無い絵は外れる")
    XCTAssertEqual(surface.primary, .body, "外した欄の焦点は本文へ移る")
    XCTAssertTrue(window.firstResponder === surface.textView, "焦点は diff の面に残る")
    XCTAssertEqual(draft.text, "書きかけ", "書きかけの欄は残る")

    remote.head = head
    state.reload()
    pumpMain(until: { shown() == ["T_above", "T_empty", "T_draft"] }, "揃うと絵が戻る")
    XCTAssertEqual(surface.rows.item(atY: surface.scrollPosition.y), top, "見えている先頭の行は動かない")
  }

  /// a.txt の新しい側の行 `line` の、未送信のコメント 1 件を持つ未解決のスレッド。
  private func stoppedThread(_ id: String, line: Int) -> GitHubPullRequestReview.Thread {
    GitHubPullRequestReview.Thread(
      id: id, path: "a.txt", lines: .at(.new, line), isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "\(id)-C", author: "me", body: "本文", createdAt: Date(), isPending: true)]
    )
  }
}
