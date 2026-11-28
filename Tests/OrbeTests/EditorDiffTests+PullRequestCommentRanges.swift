import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 範囲のコメント——行の頭の印で引いた範囲に欄が開き、範囲の行が書いている範囲の地になり、送ると始まりの行つきのスレッドを
/// 書く。読んだ範囲のスレッドは、範囲の全部の行がスレッドの地になる。壊れると、範囲のコメントが 1 行のコメントとして積まれる・
/// 別のまとまりにまたがる範囲の欄が開く・範囲のスレッドの行の地が変わらない。
extension EditorDiffTests {
  /// インラインで削除行（古い側の行 3）から追加の行（新しい側の行 3）まで引くと、その範囲の欄が開き、両方の行が書いている
  /// 範囲の地になる。送ると、始まりの行と側を持つスレッドを 1 回書く。
  func testARangeFromARemovedLineToAnAddedLineWritesARangeThread() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .source(2), to: .document(2))
    let range = DiffLineRange(
      start: DiffLine(version: .old, line: 2), end: DiffLine(version: .new, line: 2))
    let draft = try XCTUnwrap(layer.draft(at: range))
    XCTAssertEqual(surface.rows.lineSpan(ofLine: 2)?.override, DiffStyle.draftOverride)
    let removed = surface.rows.contents.compactMap { content -> [InsertedLine]? in
      if case .lines(let lines) = content { return lines }
      return nil
    }.flatMap { $0 }
    XCTAssertEqual(removed.map(\.override), [DiffStyle.draftOverride], "削除行も書いている範囲の地")
    surface.replaceText(of: draft.field, with: "範囲")
    draft.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { layer.draft(at: range) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [
        .addThread(
          path: "a.txt",
          lines: GitHubLineRange(
            start: GitHubLine(side: .old, line: 3), end: GitHubLine(side: .new, line: 3)),
          commit: remote.head, body: "範囲")
      ])
  }

  /// 範囲のスレッドは、範囲の全部の行がスレッドの地になり、絵は終わりの行の下に置く。
  func testARangeThreadGroundsAllItsRows() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt",
        lines: GitHubLineRange(
          start: GitHubLine(side: .new, line: 1), end: GitHubLine(side: .new, line: 3)),
        isResolved: false, canReply: true, canResolve: true, canUnresolve: false,
        comments: [
          .init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: true)
        ])
    ]
    let (diff, surface) = try commentedDiff(remote)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    XCTAssertEqual(
      (0..<4).map { surface.rows.lineSpan(ofLine: $0)?.override },
      [DiffStyle.threadOverride, DiffStyle.threadOverride, DiffStyle.threadOverride, nil])
    XCTAssertEqual(
      surface.rows.boundaries[try XCTUnwrap(surface.rows.block(ofZone: ObjectIdentifier(zone)))], 3,
      "終わりの行の下")
  }

  /// 欄は、両端がコメントできる行であり、かつ同じまとまりに入るときだけ開く——コメントできない行と、まとまりをまたぐ範囲には
  /// 開かない（キー c は、選択の行の範囲をそのまま、欄を開くこの口へ渡す）。
  func testADraftOpensOnlyOnARangeInsideOneHunk() throws {
    let lines = (0..<20).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "twenty lines"]).isSuccess)
    var edited = lines
    edited[1] = "LINE 1"
    edited[18] = "LINE 18"
    let (diff, _) = try commentedDiff(Remote()) {
      try self.repo.write("a.txt", edited.joined(separator: "\n") + "\n")
    }
    let layer = try XCTUnwrap(diff.comments)
    let across = DiffLineRange(
      start: DiffLine(version: .new, line: 2), end: DiffLine(version: .new, line: 16))
    XCTAssertFalse(layer.openDraft(.at(.new, 9)), "コメントできない行")
    XCTAssertFalse(layer.openDraft(across), "まとまりをまたぐ範囲")
    XCTAssertNil(layer.draft(at: .at(.new, 9)))
    XCTAssertNil(layer.draft(at: across))
    XCTAssertTrue(layer.openDraft(.at(.new, 2)), "前提: まとまりの中の行には開く")
  }
}
