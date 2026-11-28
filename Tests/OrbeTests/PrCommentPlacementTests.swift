import OrbeTestSupport
import XCTest

@testable import Orbe

/// 行を追う欄の置き場所——diff の両端が替わると行を新しい版へ移し、移した行に印を出せると確かめ終えるまで送れない姿にする。
/// 壊れると、push の直後に古い行の番号のまま新しいコミットへ書ける・確かめる前に次の push が来た欄が「移している」姿で
/// 固まって送れなくなる・印を出せない行へ移った欄が送れる・書き換えられた行が後の push で元に戻っても、欄が行の無い姿のまま
/// 送れない。
@MainActor
final class PrCommentPlacementTests: OrbeTestCase {
  private let base = "one\ntwo\nthree\nfour\n"
  private let ends = PullRequestState.DiffEnds(mergeBase: "B", head: "H1", renames: [:])

  /// 新しい側の行 `line` に、両端 `ends` の版（新しい側の本文 `base`）で数えた欄。
  private func placement(line: Int) -> PrCommentPlacement {
    PrCommentPlacement(
      zone: PrCommentZone(subject: .draft(0), lines: .at(.new, line + 1), fieldID: "draft"),
      origin: PullRequestState.CommentSpot(
        range: .at(.new, line), ends: ends, basis: EditorDiff.SideTexts(old: base, new: base)))
  }

  /// 両端 `head` の版（新しい側の本文 `text`）へ追わせ、行差分を取り終えるまで待つ。
  private func follow(_ placement: PrCommentPlacement, to head: String, _ text: String) {
    var done = false
    placement.follow(
      PullRequestState.DiffEnds(mergeBase: "B", head: head, renames: [:]),
      shown: EditorDiff.SideTexts(old: base, new: text), commentable: nil
    ) { done = true }
    pumpMain(until: { done }, "行差分を取り終える")
  }

  /// 行を移し終えても、移した行に印を出せると確かめるまでは送れない。確かめれば送れ、印を出せない行なら行が無くなる。
  func testAMovedLineCannotBeSentUntilItIsChecked() {
    let kept = placement(line: 3)
    follow(kept, to: "H2", "zero\n" + base)
    XCTAssertEqual(kept.range, .at(.new, 4))
    XCTAssertFalse(kept.zone.canSend, "移し終えても、確かめるまでは送れない")

    let current = PullRequestState.DiffEnds(mergeBase: "B", head: "H2", renames: [:])
    let shown = EditorDiff.SideTexts(old: base, new: "zero\n" + base)
    kept.follow(current, shown: shown, commentable: Self.hunks(new: 0..<5)) {}
    XCTAssertTrue(kept.zone.canSend)
    XCTAssertFalse(kept.isGone)

    let outside = placement(line: 3)
    follow(outside, to: "H2", "zero\n" + base)
    outside.follow(current, shown: shown, commentable: Self.hunks(new: 0..<2)) {}
    XCTAssertTrue(outside.isGone, "印を出せない行は無くなったとする")
  }

  /// 確かめる前に次の両端が来ても、移し終えた後に追い直せばその両端へ移る（移している姿で固まらない）。
  func testANewerHeadBeforeTheCheckIsFollowedAgain() {
    let placement = placement(line: 3)
    follow(placement, to: "H2", "zero\n" + base)
    follow(placement, to: "H3", "zero\nzero\n" + base)
    XCTAssertEqual(placement.ends.head, "H3")
    XCTAssertEqual(placement.range, .at(.new, 5))
  }

  /// 書き換えられて行が無くなった欄も、後の版でその行が元に戻れば、欄を開いた行に戻って送れる（行は欄を開いた版から導き直し、
  /// 前の版で導いた行から継ぎ足さない）。
  func testALineGoneInOneHeadComesBackWhenALaterHeadRestoresIt() {
    let placement = placement(line: 2)
    follow(placement, to: "H2", "one\ntwo\nTRES\nfour\n")
    XCTAssertTrue(placement.isGone, "前提: 書き換えられた行は無くなる")

    follow(placement, to: "H3", base)
    placement.follow(
      PullRequestState.DiffEnds(mergeBase: "B", head: "H3", renames: [:]),
      shown: EditorDiff.SideTexts(old: base, new: base), commentable: Self.hunks(new: 0..<4)
    ) {}
    XCTAssertEqual(placement.range, .at(.new, 2))
    XCTAssertFalse(placement.isGone)
    XCTAssertTrue(placement.zone.canSend)
  }

  /// 範囲の欄は、範囲の行に変更が掛からなければ丸ごとずれ、範囲の内側に行が足されるか、範囲の行が書き換えられれば行が無くなる。
  /// 導いた範囲の両端が同じまとまりに入らなければ、行が無くなる。
  func testARangeMovesWholeOrIsGone() {
    let range = DiffLineRange(
      start: DiffLine(version: .new, line: 1), end: DiffLine(version: .new, line: 2))
    let spot = { (text: String) in
      PrCommentPlacement.target(
        of: range, from: EditorDiff.SideTexts(old: self.base, new: self.base),
        to: EditorDiff.SideTexts(old: self.base, new: text), limit: EditorDiff.hunkLimit)
    }
    let moved = spot("zero\n" + base)
    XCTAssertFalse(moved.isGone)
    XCTAssertEqual(moved.range.start?.line, 2)
    XCTAssertEqual(moved.range.end.line, 3)
    XCTAssertTrue(spot("one\ntwo\nadded\nthree\nfour\n").isGone, "範囲の内側に足された行")
    XCTAssertTrue(spot("one\nTWO\nthree\nfour\n").isGone, "書き換えられた始まりの行")
    XCTAssertFalse(spot("one\ntwo\nthree\nadded\nfour\n").isGone, "範囲の後に足された行")

    let hunks = DiffRows.CommentHunks(items: [
      .init(old: 0..<0, new: 0..<2), .init(old: 0..<0, new: 2..<4),
    ])
    XCTAssertFalse(hunks.holds(range), "両端が別のまとまり")
    XCTAssertTrue(Self.hunks(new: 0..<4).holds(range))
  }

  /// 側をまたぐ範囲（削除行から追加の行まで）は、両端をそれぞれの側の変更の分だけずらす。範囲が覆う行のどれかが、どちらかの側で
  /// 書き換えられれば、範囲の行が無くなった（欄から送れない）とする。
  func testARangeAcrossSidesMovesEachSideOrIsGone() {
    let changed = "one\ntwo\nTHREE\nfour\n"
    let range = DiffLineRange(
      start: DiffLine(version: .old, line: 2), end: DiffLine(version: .new, line: 2))
    let spot = { (old: String, new: String) in
      PrCommentPlacement.target(
        of: range, from: EditorDiff.SideTexts(old: self.base, new: changed),
        to: EditorDiff.SideTexts(old: old, new: new), limit: EditorDiff.hunkLimit)
    }
    let pushed = spot(base, "zero\n" + changed)
    XCTAssertFalse(pushed.isGone)
    XCTAssertEqual(pushed.range.start, DiffLine(version: .old, line: 2), "古い側は変わらない")
    XCTAssertEqual(pushed.range.end, DiffLine(version: .new, line: 3))
    let rebased = spot("zero\n" + base, changed)
    XCTAssertFalse(rebased.isGone)
    XCTAssertEqual(rebased.range.start, DiffLine(version: .old, line: 3), "古い側だけずれる")
    XCTAssertEqual(rebased.range.end, DiffLine(version: .new, line: 2))
    XCTAssertTrue(spot(base, "one\ntwo\nTHREE!\nfour\n").isGone, "書き換えられた新しい側の行")
    XCTAssertTrue(spot("one\ntwo\nthree!\nfour\n", changed).isGone, "書き換えられた古い側の行")
  }

  /// 新しい側の行 `new` だけのまとまり 1 つ。
  private static func hunks(new: Range<Int>) -> DiffRows.CommentHunks {
    DiffRows.CommentHunks(items: [.init(old: 0..<0, new: new)])
  }
}
