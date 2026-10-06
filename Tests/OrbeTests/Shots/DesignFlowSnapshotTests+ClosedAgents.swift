import OrbeSessionLog
import SwiftUI
import XCTest

@testable import Orbe

/// ⇧⌘T「閉じたエージェント」パレットの flow（ファイル分割の拡張。撮り方は本体の `flow` を共有する）。
/// 窓は「リストが cap（`PaletteCard.capHeight` 320）で頭打ちになる」ところまで高くする。
/// これより低いと止めているのが窓であって cap ではなくなり、cap 超えの画が撮れない。
private let closedAgentsFlowCardSize = NSSize(width: 560, height: 560)
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
  /// `d` は OSC タイトル未受信のまま閉じた既定ケース——記録された title が cwd 由来の派生名で、
  /// 主役と脇の末尾が同じ語になる。経過時間は分の境界から離す（コマ間の 0.2 秒で表示が変わらない）。
  var list: [ClosedAgentItem] {
    [
      item("g", "release notes", closedAgentsRoot + "/Sources/Orbe", ago: 45, origin: .gesture),
      item(
        "d", TabTitle.derive(pwd: closedAgentsRoot, root: closedAgentsRoot), closedAgentsRoot,
        ago: 3 * 60 + 20, origin: .process),
      item("a", "PR #142 レビュー対応", closedAgentsRoot, ago: 8 * 60, origin: .agent),
      item(
        "p3", "docs-sync", closedAgentsRoot + "/Tests", ago: 30 * 60 + 20, origin: .process),
      item(
        "p2", "renderer-tests", closedAgentsRoot + "/docs/spec", ago: 30 * 60 + 22,
        origin: .process),
      item(
        "p1", "deploy-api", closedAgentsRoot + "/Sources/orbe-cli", ago: 30 * 60 + 25,
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
  /// 空状態 → 一覧 → ↓ で選択 → ⌘↓ で末尾（cap で隠れた行と 5 種目のバッジが出る）→ 最悪ケース。
  /// 状態は本物の `ClosedAgentsPaletteModel` のアクションが生む。
  func testClosedAgents() throws {
    let fixture = ClosedAgentsFixture(now: Date())
    let l10n = LocalizationStore(language: .ja)
    let palette = ClosedAgentsPaletteModel(localization: l10n)
    try flow(
      "closed_agents", size: closedAgentsFlowCardSize,
      render: {
        paletteOverlaySnapshot(palette.render, canvas: closedAgentsFlowCardSize)
          .environment(\.localization, l10n)
      },
      steps: [
        ("empty", { palette.setItems([]) }),
        ("list", { palette.setItems(fixture.list) }),
        ("down", { palette.render.onDown() }),
        ("bottom", { palette.render.onJumpBottom() }),
        ("worst", { palette.setItems(fixture.worst) }),
      ])
  }
}
