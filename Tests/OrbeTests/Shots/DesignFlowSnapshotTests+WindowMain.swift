import AppKit
import XCTest

@testable import Orbe

extension DesignFlowSnapshotTests {
  /// 窓の main の得失: 製品の根（`AppShell`）が `windowIsMain` を配り、上段・タブ行・グローが前面 → 退いた姿 → 前面へ
  /// 切り替わる過程を撮る。
  func testWindowMain() throws {
    let size = NSSize(width: 640, height: 240)
    let status = StatusRowModel()
    status.workspace = "orbe"
    status.strip = TabStrip(
      titles: ["window-look", "editor", "~/notes"],
      glyphs: [.working, .waiting, .done],
      segments: [0..<2, 2..<3],
      colorIndices: ["orbe", "notes"].map { WorktreeColor.index(forKey: $0) })
    status.selection = .tab(0)
    status.location = [.dim("~/dev/orbe/"), .text("Sources/Orbe/App/Layout/AppShell.swift")]
    status.faceDots = .init(editor: .focus, terminal: .on)
    status.rollup = [("working", 1), ("waiting", 1), ("done", 1)]
    let model = AppShellModel(statusModel: status, content: NSView())
    try flow(
      "window_main", size: size,
      render: {
        AppShell(
          model: model, translucency: ChromeTranslucency(), agentIconResolver: AgentIconResolver(),
          fontResolver: ChromeFontResolver(), localization: LocalizationStore(language: .ja))
      },
      steps: [
        ("main", { model.windowIsMain = true }),
        ("not_main", { model.windowIsMain = false }),
        ("main_again", { model.windowIsMain = true }),
      ])
  }
}
