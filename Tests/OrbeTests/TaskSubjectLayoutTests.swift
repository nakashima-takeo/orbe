import XCTest

@testable import Orbe

/// 表の件名の幅の配り方（`TaskSubjectLayout.widths`）。子は番号・タイトル・続く札と補足の順。
///
/// 壊れると何が起きるか: 狭い窓や札の多い行で、件名で最も大事なタイトルが札に押されて消える。途中で切れた読めない札が
/// 出る。今動いている agent の補足が、ほかの札より先に消える。
@MainActor
final class TaskSubjectLayoutTests: OrbeTestCase {
  private let layout = TaskSubjectLayout(spacing: 4, titleMinWidth: 100)

  private enum Order {
    static let review = 0
    static let pullRequest = 1
    static let resolved = 2
    static let agent = 3
  }

  /// タイトルが最小幅まで縮んでも足りなければ、札を「レビュー」→ PR の札 → 起きたこと → agent の順にまるごと外す。
  func testBadgesAreDroppedWholeInOrderLeavingTheAgentLastWhileTheTitleKeepsItsMinimum() {
    // 番号 20・タイトル 300・レビュー 30・PR 60・起きたこと 40・agent 50。
    let ideals: [CGFloat] = [20, 300, 30, 60, 40, 50]
    let orders: [Int?] = [nil, nil, Order.review, Order.pullRequest, Order.resolved, Order.agent]
    func widths(_ available: CGFloat) -> [CGFloat] {
      layout.widths(ideals: ideals, dropOrders: orders, available: available)
    }
    // 番号とタイトルの最小幅の分。札は間 4 を足して数える。
    let floor: CGFloat = 24 + 100

    XCTAssertEqual(widths(1000), ideals, "入るなら理想の幅のまま")
    XCTAssertEqual(widths(floor + 64 + 44 + 54), [20, 100, 0, 60, 40, 50])
    XCTAssertEqual(widths(floor + 44 + 54), [20, 100, 0, 0, 40, 50])
    XCTAssertEqual(widths(floor + 54), [20, 100, 0, 0, 0, 50])
    XCTAssertEqual(widths(floor), [20, 100, 0, 0, 0, 0])
  }

  /// 札でない補足（待ちの理由）は外さず、札を残した後の残りの幅に縮む。
  func testTheWaitingReasonShrinksIntoTheRestInsteadOfBeingDropped() {
    let widths = layout.widths(
      ideals: [0, 300, 200, 50], dropOrders: [nil, nil, nil, Order.agent], available: 200)

    XCTAssertEqual(widths, [0, 100, 42, 50], "タイトルは最小幅、agent は残し、理由は残り 46 から間を引いた幅")
  }

  /// 件名の列そのものが最小幅より狭ければ、タイトルは列の幅に収まり、札はすべて外れる。
  func testATitleInAColumnNarrowerThanItsMinimumFitsTheColumn() {
    let widths = layout.widths(
      ideals: [20, 300, 60], dropOrders: [nil, nil, Order.pullRequest], available: 84)

    XCTAssertEqual(widths, [20, 60, 0])
  }
}
