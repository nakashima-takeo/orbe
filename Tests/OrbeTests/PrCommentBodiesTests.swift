import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 本文の幅ごとに組んだコメントの本文の覚え。壊れると、幅を行き来するたびに本文を組み直して絵がちらつく・覚えの無い幅に
/// 移った間の本文が消える・書き換わったコメントの古い本文が出る。
@MainActor
final class PrCommentBodiesTests: OrbeTestCase {
  private let comment = (id: "C", body: "折り返す長さの本文。折り返す長さの本文。折り返す長さの本文。")

  /// 幅 `width` で問い、組み終えるまで待つ。
  private func typeset(_ bodies: PrCommentBodies, width: CGFloat) {
    _ = bodies.bodies([comment], width: width)
    pumpMain(until: { !bodies.isTypesetting }, "幅 \(width) で組み終える")
  }

  /// 最近使った幅の覚えは、新しい幅を組んでも残り、問い直しても組み直さない。覚える幅には上限があり、使ってから最も時の
  /// 経った幅から捨てる（ライブリサイズで幅ごとの本文が溜まらない）。
  func testARecentlyUsedWidthStaysAfterNewWidths() {
    let bodies = PrCommentBodies()
    for width: CGFloat in [100, 200, 300] { typeset(bodies, width: width) }
    _ = bodies.bodies([comment], width: 100)
    XCTAssertFalse(bodies.isTypesetting, "覚えた幅は組み直さない")
    typeset(bodies, width: 400)

    _ = bodies.bodies([comment], width: 100)
    XCTAssertFalse(bodies.isTypesetting, "使い直した幅は、新しい幅を組んでも捨てない")
    _ = bodies.bodies([comment], width: 200)
    XCTAssertTrue(bodies.isTypesetting, "使ってから最も時の経った幅は捨てる")
  }

  /// 覚えの無い幅では、裏で組む間、同じ本文をほかの幅で組んだものを返す。書き換わったコメントには、古い本文を返さない。
  func testAnUnknownWidthLendsAnotherWidthButNeverAStaleBody() throws {
    let bodies = PrCommentBodies()
    typeset(bodies, width: 100)

    let lent = try XCTUnwrap(bodies.bodies([comment], width: 300)[comment.id])
    XCTAssertTrue(bodies.isTypesetting)
    XCTAssertEqual(lent.source, comment.body)
    pumpMain(until: { !bodies.isTypesetting }, "幅 300 で組み終える")

    let edited = (id: comment.id, body: "書き換えた本文")
    XCTAssertNil(bodies.bodies([edited], width: 300)[comment.id])
    pumpMain(until: { !bodies.isTypesetting }, "書き換えた本文を組み終える")
    XCTAssertEqual(bodies.bodies([edited], width: 300)[comment.id]?.source, edited.body)
  }

  /// スレッドの絵を描き直しても（ホバー）、組み終えた本文の層は同じ参照のまま置く（面が層を写し直さず、長い本文でも描き直しが
  /// 本文の長さに比例しない）。
  func testARedrawnThreadKeepsTheSameBodyLayer() throws {
    let zone = PrCommentZone(
      subject: .thread(
        GitHubPullRequestReview.Thread(
          id: "T", path: "a.txt", lines: .at(.new, 1), isResolved: false, canReply: true,
          canResolve: true, canUnresolve: false,
          comments: [
            .init(
              id: comment.id, author: "you", body: comment.body, createdAt: Date(), isPending: false
            )
          ])), lines: .at(.new, 1), fieldID: "thread:T")
    _ = zone.picture(width: 600)
    pumpMain(until: { !zone.isTypesetting }, "本文を組み終える")
    let bodyLayers = { (picture: ZonePicture) in
      picture.layers.map(\.layer).filter { !$0.texts.isEmpty }
    }
    let before = bodyLayers(zone.picture(width: 600))
    XCTAssertEqual(before.count, 1, "前提: 本文の層がある")

    zone.zone(.entered(PrCommentControl.resolve))
    let after = bodyLayers(zone.picture(width: 600))
    XCTAssertEqual(after.count, 1)
    XCTAssertTrue(after.first === before.first)
  }
}
