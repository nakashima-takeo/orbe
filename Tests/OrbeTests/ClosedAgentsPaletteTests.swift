import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// ⇧⌘T パレットの状態機械。↵ が選んだ 1 件だけを復元すること、Esc が閉じること、開いたまま一覧が
/// 差し替わるときの選択の錨を固定する。壊れると ↵ が選んだ覚えのない行を復元するか、1 件戻した瞬間に
/// 選択が一覧の先頭へ跳ねる。
@MainActor
final class ClosedAgentsPaletteTests: OrbeTestCase {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  private func item(
    _ id: String, at seconds: TimeInterval, origin: SessionEvent.CloseOrigin = .process,
    title: String? = nil
  ) -> ClosedAgentItem {
    ClosedAgentItem(
      sessionId: id, command: "claude", cwd: "/repo/\(id)", rootPath: "/repo", title: title,
      closedAt: base.addingTimeInterval(seconds), origin: origin)
  }

  private func model(_ items: [ClosedAgentItem]) -> (ClosedAgentsPaletteModel, () -> [String]) {
    let m = ClosedAgentsPaletteModel(localization: LocalizationStore(language: .ja))
    var restored: [String] = []
    m.onRestore = { restored.append($0.sessionId) }
    m.setItems(items)
    return (m, { restored })
  }

  func testEmptyShowsOneInformationRowAndEnterDoesNothing() {
    let (m, restored) = model([])
    XCTAssertEqual(m.render.rows.count, 1)
    XCTAssertFalse(m.render.rows[0].enabled)
    m.activate()
    XCTAssertEqual(restored(), [])
  }

  func testRowsAreFlatWithTitleAsLabelAndEnterRestoresOnlyTheSelectedOne() {
    let (m, restored) = model([
      item("c", at: 100, origin: .gesture, title: "release notes"),
      item("b", at: 12), item("a", at: 10),
    ])
    XCTAssertEqual(m.render.rows.map(\.label), ["release notes", "Terminal", "Terminal"])

    m.render.selected = 1
    m.activate()
    XCTAssertEqual(restored(), ["b"], "↵ は選んだ 1 件だけ")
  }

  func testSelectionFollowsTheSessionWhenNewerRowsArriveOrOthersLeave() {
    let (m, _) = model([item("b", at: 12), item("a", at: 10)])
    m.render.selected = 1  // a

    m.setItems([item("z", at: 500), item("b", at: 12), item("a", at: 10)])
    XCTAssertEqual(m.render.selected, 2, "選択は index でなく sessionId に追随する")

    m.setItems([item("z", at: 500), item("a", at: 10)])
    XCTAssertEqual(m.render.selected, 1, "他の行が戻って消えても a を追える")

    m.setItems([item("z", at: 500)])
    XCTAssertEqual(m.render.selected, 0, "錨が消えたら末尾に収める")
  }

  func testEscapeDismisses() {
    let (m, _) = model([item("a", at: 10)])
    var dismissed = false
    m.onDismiss = { dismissed = true }
    m.render.onEscape()
    XCTAssertTrue(dismissed)
  }
}
