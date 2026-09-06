import OrbeSessionLog
import SwiftUI
import XCTest

@testable import Orbe

/// ⇧⌘T「閉じたエージェント」パレットの flow（ファイル分割の拡張。撮り方は本体の `flow` を共有する）。
private let closedAgentsFlowCardSize = NSSize(width: 560, height: 360)
private let closedAgentsRoot = "/Users/me/orbe"

private func closedItem(
  _ id: String, _ cwd: String, ago: TimeInterval, origin: SessionEvent.CloseOrigin,
  reason: String? = nil, now: Date
) -> ClosedAgentItem {
  ClosedAgentItem(
    sessionId: id, command: "claude", cwd: cwd, rootPath: closedAgentsRoot,
    closedAt: now.addingTimeInterval(-ago), origin: origin, reason: reason)
}

private func closedGroup(
  _ items: [ClosedAgentItem], origin: SessionEvent.CloseOrigin, now: Date
) -> ClosedAgentGroup {
  let at = items.map(\.closedAt).min() ?? now
  return ClosedAgentGroup(at: at, atKey: SessionEvent.iso8601(at), origin: origin, items: items)
}

/// 各 origin のバッジ・reason 付きの 1 件行・3 件の群行が 1 画に並ぶ普段の一覧。
private func closedAgentsGroups(now: Date) -> [ClosedAgentGroup] {
  func item(
    _ id: String, _ cwd: String, ago: TimeInterval, origin: SessionEvent.CloseOrigin,
    reason: String? = nil
  ) -> ClosedAgentItem {
    closedItem(id, cwd, ago: ago, origin: origin, reason: reason, now: now)
  }
  func group(_ items: [ClosedAgentItem], _ origin: SessionEvent.CloseOrigin) -> ClosedAgentGroup {
    closedGroup(items, origin: origin, now: now)
  }
  return [
    group([item("g", closedAgentsRoot + "/Sources/Orbe", ago: 45, origin: .gesture)], .gesture),
    group([item("a", closedAgentsRoot, ago: 8 * 60, origin: .agent, reason: "logout")], .agent),
    group(
      [
        item("p3", closedAgentsRoot + "/Tests", ago: 30 * 60 - 3, origin: .process),
        item("p2", closedAgentsRoot + "/docs/spec", ago: 30 * 60 - 1, origin: .process),
        item("p1", closedAgentsRoot + "/Sources/orbe-cli", ago: 30 * 60, origin: .process),
      ], .process),
    group(
      [item("c", closedAgentsRoot + "/scripts", ago: 2 * 3600, origin: .controlAPI)], .controlAPI),
    group([item("u", closedAgentsRoot, ago: 3 * 86400, origin: .unresolved)], .unresolved),
  ]
}

/// 最悪ケース: 深い cwd・長い reason・多い件数。右端の列（バッジ・経過時間・潜れる印）が生き残り、
/// 溢れは cwd の末尾省略に落ちること、行が cap を超えて内部スクロールに入ることを画で見る。
private func closedAgentsWorstGroups(now: Date) -> [ClosedAgentGroup] {
  let deep = closedAgentsRoot + "/Sources/Orbe/Features/ClosedAgents/Internal/Rendering/Rows"
  return [
    closedGroup(
      [
        closedItem(
          "w1", deep, ago: 12, origin: .unresolved,
          reason: "resume に失敗しました: セッションファイルが見つかりません (~/.claude/projects/…)", now: now)
      ], origin: .unresolved, now: now),
    closedGroup(
      (0..<9).map {
        closedItem(
          "m\($0)", "\(deep)/\($0)", ago: TimeInterval(600 + $0), origin: .process, now: now)
      }, origin: .process, now: now),
  ]
}

extension DesignFlowSnapshotTests {
  /// 空状態 → 一覧 → ↓ で選択 → → で群に潜る → ← で戻る → 最悪ケースの一覧とその中身。
  /// 状態は本物の `ClosedAgentsPaletteModel` のアクションが生む（drill / back の breadcrumb と hint も画に出る）。
  func testClosedAgents() throws {
    let now = Date()
    let groups = closedAgentsGroups(now: now)
    let worst = closedAgentsWorstGroups(now: now)
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
        // 選択は末尾（＝ 9 件の群行）へ明示的に置き、次の → を決定的にする。
        (
          "worst",
          {
            palette.setGroups(worst)
            palette.render.onJumpBottom()
          }
        ),
        ("worst_drill", { _ = palette.render.onRight() }),  // 9 件の中身
      ])
  }
}
