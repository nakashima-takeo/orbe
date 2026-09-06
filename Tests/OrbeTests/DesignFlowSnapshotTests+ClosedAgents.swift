import OrbeSessionLog
import SwiftUI
import XCTest

@testable import Orbe

/// ⇧⌘T「閉じたエージェント」パレットの flow（ファイル分割の拡張。撮り方は本体の `flow` を共有する）。
private let closedAgentsFlowCardSize = NSSize(width: 560, height: 360)
private let closedAgentsRoot = "/Users/me/orbe"

/// flow の素材。`now` からの経過で閉じた時刻を組む。
private struct ClosedAgentsFixture {
  let now: Date

  func item(
    _ id: String, _ title: String?, _ cwd: String, ago: TimeInterval,
    origin: SessionEvent.CloseOrigin
  ) -> ClosedAgentItem {
    ClosedAgentItem(
      sessionId: id, command: "claude", cwd: cwd, rootPath: closedAgentsRoot, title: title,
      closedAt: now.addingTimeInterval(-ago), origin: origin)
  }

  /// 各 origin のバッジが 1 つずつ揃うタイトル付きの一覧。同じ事故で落ちた 3 行（process）はそのまま並ぶ。
  var list: [ClosedAgentItem] {
    [
      item("g", "release notes", closedAgentsRoot + "/Sources/Orbe", ago: 45, origin: .gesture),
      item("a", "PR #142 レビュー対応", closedAgentsRoot, ago: 8 * 60, origin: .agent),
      item("p3", "docs-sync", closedAgentsRoot + "/Tests", ago: 30 * 60 - 3, origin: .process),
      item(
        "p2", "renderer-tests", closedAgentsRoot + "/docs/spec", ago: 30 * 60 - 1,
        origin: .process),
      item(
        "p1", "deploy-api", closedAgentsRoot + "/Sources/orbe-cli", ago: 30 * 60,
        origin: .process),
      item("c", "swift test", closedAgentsRoot + "/scripts", ago: 2 * 3600, origin: .controlAPI),
      item("u", "emit API 設計", closedAgentsRoot, ago: 3 * 86400, origin: .unresolved),
    ]
  }

  /// 最悪ケース: 幅を超える長いタイトル・深い cwd・title 無しの `Terminal` 行・cap を超える件数。
  /// タイトルが末尾省略で 1 行に収まり、脇の CLI・cwd・バッジ・経過時間が右端の列で揃い、
  /// 行が cap を超えて内部スクロールに入ることを画で見る。
  var worst: [ClosedAgentItem] {
    let deep = closedAgentsRoot + "/Sources/Orbe/Features/ClosedAgents/Internal/Rendering/Rows"
    let long = String(repeating: "とても長いタイトル", count: 12)
    return [
      item("w1", long, deep, ago: 12, origin: .unresolved),
      item("w2", nil, deep, ago: 40, origin: .gesture),
    ]
      + (0..<9).map {
        item(
          "m\($0)", "worker-\($0)", "\(deep)/\($0)", ago: TimeInterval(600 + $0), origin: .process)
      }
  }
}

extension DesignFlowSnapshotTests {
  /// 空状態 → 一覧 → ↓ で選択 → 最悪ケース。状態は本物の `ClosedAgentsPaletteModel` のアクションが生む。
  func testClosedAgents() throws {
    let fixture = ClosedAgentsFixture(now: Date())
    let palette = ClosedAgentsPaletteModel(localization: LocalizationStore(language: .ja))
    try flow(
      "closed_agents", size: closedAgentsFlowCardSize,
      render: { paletteOverlaySnapshot(palette.render, canvas: closedAgentsFlowCardSize) },
      steps: [
        ("empty", { palette.setItems([]) }),
        ("list", { palette.setItems(fixture.list) }),
        ("down", { palette.render.onDown() }),
        ("worst", { palette.setItems(fixture.worst) }),
      ])
  }
}
