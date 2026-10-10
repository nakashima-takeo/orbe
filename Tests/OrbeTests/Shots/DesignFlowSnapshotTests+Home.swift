import AppKit
import XCTest

@testable import Orbe

extension DesignFlowSnapshotTests {
  /// Home: 最上段の Home 行（休眠で減光・state フォルダの下の長いパス）→ 2 段目の default → 他、の一覧と、
  /// 行ごとに出し分ける詳細メニュー（Home 行は改名だけ・通常行は改名／ディレクトリ／削除）を撮る。
  func testWorkspaceHome() throws {
    let size = NSSize(width: 500, height: 320)
    let workspace = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    let stateDir = NSHomeDirectory() + "/Library/Application Support/dev.orbe.app.dev"
    let items = [
      WorkspacePaletteModel.Item(
        index: 2, name: "Home", isActive: false, dir: stateDir + "/home",
        canSetDir: false, canClose: false, live: .init(rollup: [], dormant: true)),
      WorkspacePaletteModel.Item(
        index: 0, name: "default", isActive: true, dir: NSHomeDirectory(), canSetDir: true,
        canClose: true, live: .init(rollup: [(state: "working", count: 1)], dormant: false)),
      WorkspacePaletteModel.Item(
        index: 1, name: "infra", isActive: false, dir: NSHomeDirectory() + "/code/infra",
        canSetDir: true, canClose: true, live: .init(rollup: [], dormant: false)),
    ]
    try flow(
      "workspace_home", size: size,
      render: { paletteSnapshot(workspace.render, canvas: size) },
      steps: [
        (
          "list",
          {
            workspace.setItems(items)
            workspace.selectActiveRow()
          }
        ),
        (
          "home_submenu",
          {
            workspace.render.selected = 0  // Home 行へ
            _ = workspace.render.onRight()
          }
        ),
        ("back", { workspace.render.onLeft() }),
        (
          "regular_submenu",
          {
            workspace.render.selected = 1  // default 行へ
            _ = workspace.render.onRight()
          }
        ),
      ])
  }
}
