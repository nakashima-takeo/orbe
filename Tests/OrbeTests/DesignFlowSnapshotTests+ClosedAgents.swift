import OrbeSessionLog
import SwiftUI
import XCTest

@testable import Orbe

/// ⇧⌘T「閉じたエージェント」パレットの flow（ファイル分割の拡張。撮り方は本体の `flow` を共有する）。
private let closedAgentsFlowCardSize = NSSize(width: 560, height: 360)

extension DesignFlowSnapshotTests {
  /// 空状態 → 一覧（各 origin のバッジ・reason 付きの 1 件行・3 件の群行）→ ↓ で選択 → → で群に潜る → ← で戻る。
  /// 状態は本物の `ClosedAgentsPaletteModel` のアクションが生む（drill / back の breadcrumb と hint も画に出る）。
  func testClosedAgents() throws {
    let now = Date()
    func item(
      _ id: String, _ cwd: String, ago: TimeInterval, origin: SessionEvent.CloseOrigin,
      reason: String? = nil
    ) -> ClosedAgentItem {
      ClosedAgentItem(
        sessionId: id, command: "claude", cwd: cwd, rootPath: "/Users/me/orbe",
        closedAt: now.addingTimeInterval(-ago), origin: origin, reason: reason)
    }
    func group(_ items: [ClosedAgentItem], origin: SessionEvent.CloseOrigin) -> ClosedAgentGroup {
      let at = items.map(\.closedAt).min() ?? now
      return ClosedAgentGroup(at: at, atKey: SessionEvent.iso8601(at), origin: origin, items: items)
    }
    let groups = [
      group(
        [item("g", "/Users/me/orbe/Sources/Orbe", ago: 45, origin: .gesture)], origin: .gesture),
      group(
        [item("a", "/Users/me/orbe", ago: 8 * 60, origin: .agent, reason: "logout")], origin: .agent
      ),
      group(
        [
          item("p3", "/Users/me/orbe/Tests", ago: 30 * 60 - 3, origin: .process),
          item("p2", "/Users/me/orbe/docs/spec", ago: 30 * 60 - 1, origin: .process),
          item("p1", "/Users/me/orbe/Sources/orbe-cli", ago: 30 * 60, origin: .process),
        ], origin: .process),
      group(
        [item("c", "/Users/me/orbe/scripts", ago: 2 * 3600, origin: .controlAPI)],
        origin: .controlAPI),
      group(
        [item("u", "/Users/me/orbe", ago: 3 * 86400, origin: .unresolved)], origin: .unresolved),
    ]
    let palette = ClosedAgentsPaletteModel(localization: LocalizationStore(language: .ja))
    try flow(
      "closed_agents", size: closedAgentsFlowCardSize,
      render: { paletteOverlaySnapshot(palette.render, canvas: closedAgentsFlowCardSize) },
      steps: [
        ("empty", { palette.setGroups([]) }),
        ("list", { palette.setGroups(groups) }),
        ("down", { palette.render.onDown() }),  // 1 件行 → 1 件行（agent・reason 付き）
        ("down_group", { palette.render.onDown() }),  // 3 件の群行へ
        ("drill", { _ = palette.render.onRight() }),  // 群の中身（breadcrumb に閉じた時刻）
        ("back", { palette.render.onLeft() }),  // 群行へ戻る（選択も復元される）
      ])
  }
}
