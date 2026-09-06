import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// ⇧⌘T パレットの状態機械。群の ↵ / → / ← と、開いたまま一覧が差し替わるときの選択の錨を固定する。
/// 壊れると ↵ が選んだ覚えのない群を復元するか、潜った群の 1 件を戻した瞬間に一覧の先頭へ跳ねる。
@MainActor
final class ClosedAgentsPaletteTests: OrbeTestCase {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  private func item(
    _ id: String, at seconds: TimeInterval, origin: SessionEvent.CloseOrigin = .process
  )
    -> ClosedAgentItem
  {
    ClosedAgentItem(
      sessionId: id, command: "claude", cwd: "/repo/\(id)", rootPath: "/repo",
      closedAt: base.addingTimeInterval(seconds), origin: origin, reason: nil)
  }

  private func group(_ items: [ClosedAgentItem], origin: SessionEvent.CloseOrigin = .process)
    -> ClosedAgentGroup
  {
    let at = items.map(\.closedAt).min() ?? base
    return ClosedAgentGroup(at: at, atKey: SessionEvent.iso8601(at), origin: origin, items: items)
  }

  private func model(_ groups: [ClosedAgentGroup]) -> (ClosedAgentsPaletteModel, () -> [[String]]) {
    let m = ClosedAgentsPaletteModel(localization: LocalizationStore(language: .ja))
    var restored: [[String]] = []
    m.onRestore = { restored.append($0.map(\.sessionId)) }
    m.setGroups(groups)
    return (m, { restored })
  }

  func testEmptyShowsOneInformationRow() {
    let (m, _) = model([])
    XCTAssertEqual(m.render.rows.count, 1)
    XCTAssertFalse(m.render.rows[0].enabled)
    m.activate()
  }

  func testEnterOnGroupRestoresAllAndEnterOnSingleRestoresOne() {
    let burst = group([item("b", at: 12), item("a", at: 10)])
    let (m, restored) = model([
      group([item("c", at: 100, origin: .gesture)], origin: .gesture), burst,
    ])
    XCTAssertEqual(m.render.rows.map(\.chevron), [false, true], "2 件以上の群だけ chevron")

    m.activate()
    m.render.selected = 1
    m.activate()
    XCTAssertEqual(restored(), [["c"], ["b", "a"]])
  }

  func testRightDrillsIntoGroupAndLeftReturnsToTheGroupRow() {
    let burst = group([item("b", at: 12), item("a", at: 10)])
    let (m, restored) = model([
      group([item("c", at: 100, origin: .gesture)], origin: .gesture), burst,
    ])

    XCTAssertFalse(m.drillIn(), "1 件行では → は消費しない")
    m.render.selected = 1
    XCTAssertTrue(m.drillIn())
    XCTAssertEqual(m.mode, .members(atKey: burst.atKey))
    XCTAssertEqual(m.render.rows.count, 2)
    XCTAssertEqual(m.render.selected, 0)
    XCTAssertTrue(m.render.breadcrumb?.hasPrefix("closed agents › ") == true)

    m.render.selected = 1
    m.activate()
    XCTAssertEqual(restored(), [["a"]], "members の ↵ はその 1 件だけ")

    m.goBack()
    XCTAssertEqual(m.mode, .groups)
    XCTAssertEqual(m.render.selected, 1, "潜った群の行へ戻る")

    var dismissed = false
    m.onDismiss = { dismissed = true }
    m.goBack()
    XCTAssertTrue(dismissed, "groups の ← / esc は閉じる")
  }

  func testSelectionFollowsGroupWhenNewerGroupArrives() {
    let old = group([item("a", at: 10)])
    let (m, _) = model([old])
    m.render.selected = 0

    m.setGroups([group([item("z", at: 500)]), old])
    XCTAssertEqual(m.render.selected, 1, "選択は index でなく群に追随する")
  }

  func testMembersFollowSessionAndFallBackToGroupsWhenTheGroupIsGone() {
    let burst = group([item("c", at: 14), item("b", at: 12), item("a", at: 10)])
    let (m, _) = model([burst])
    m.drillIn()
    m.render.selected = 2  // a

    // b が戻って群から消えても、群の at は動かず a を追える。
    m.setGroups([
      ClosedAgentGroup(
        at: burst.at, atKey: burst.atKey, origin: .process,
        items: [item("c", at: 14), item("a", at: 10)])
    ])
    XCTAssertEqual(m.mode, .members(atKey: burst.atKey))
    XCTAssertEqual(m.render.selected, 1)

    m.setGroups([])
    XCTAssertEqual(m.mode, .groups, "全件戻ったら groups へ")
    XCTAssertEqual(m.render.rows.count, 1)
  }
}
