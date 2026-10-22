import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ソース管理パネルの階層の flow（fixture は `ScmFixtures`）: 親「ソース管理」を開いて変更の行を選ぶ → 子の見出しを選ぶ →
/// グラフの見出しに乗る（地は見出しの帯だけ）→ 境目を上へ引く（グラフの枠が伸びる）→ グラフを畳む（見出しが下端に寄る）→
/// 親を畳む（グラフの枠が上へ伸びる）→ 両方畳む → 両方開いてサイドバーを幅 190 に狭める。階層の見た目を確かめるので、
/// 各手順を dark と light（`_light`）の両方で撮る。
extension DesignFlowSnapshotTests {
  func testEditorScmLayers() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "行・グラフ・HEAD の push 済みが揃う")
    let panel = scene.panel
    let pane = scene.pane
    let width = pane.sidebar.width
    defer { pane.sidebar.setWidth(width) }
    let graphHeight = pane.sidebar.graphHeight
    defer { pane.sidebar.setGraphHeight(graphHeight) }
    var hovers = false
    var rise: CGFloat?
    let steps: [(label: String, action: () -> Void)] = [
      ("open", { panel.select(ScmRowID(section: .changes, path: "src/agent/StateHooks.swift")) }),
      ("header_selected", { panel.select(ScmRowID(section: .changes, path: nil)) }),
      ("graph_hover", { hovers = true }),
      ("resized", { (hovers, rise) = (false, 66) }),
      ("graph_closed", { panel.isGraphOpen.toggle() }),
      (
        "repository_closed",
        {
          panel.isGraphOpen.toggle()
          panel.setRepositoryOpen(false)
        }
      ),
      ("both_closed", { panel.isGraphOpen.toggle() }),
      (
        "narrow",
        {
          panel.isGraphOpen.toggle()
          panel.setRepositoryOpen(true)
          pane.sidebar.setGraphHeight(graphHeight)
          pane.sidebar.setWidth(190)
        }
      ),
    ]
    let size = NSSize(width: 1100, height: 640)
    for (index, step) in steps.enumerated() {
      step.action()
      for dark in [true, false] {
        let data = try XCTUnwrap(
          renderPNG(
            scene.view, size: size, dark: dark,
            until: {
              guard panel.isHeadPushed != nil else { return false }
              if let amount = rise {
                Self.dragHandle(in: pane, by: amount)
                rise = nil
              }
              if hovers { Self.hoverGraphHeader(in: pane) }
              return true
            }))
        let name = String(
          format: "editor_scm_layers_%02d_%@%@.png", index, step.label, dark ? "" : "_light")
        let url = previewDir("flows").appendingPathComponent(name)
        try data.write(to: url)
        print("[flow] wrote \(url.path)")
      }
    }
  }

  /// 境目の当たりを掴んで上へ `rise` 引いて離す（窓の座標で）。
  private static func dragHandle(in pane: EditorPaneView, by rise: CGFloat) {
    guard let handle = view(ScmSplitHandleView.self, in: pane), let window = handle.window else {
      return
    }
    let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
    handle.mouseDown(with: .mouse(.leftMouseDown, at: start, in: window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + rise), in: window))
    handle.mouseUp(
      with: .mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y + rise), in: window))
    pane.layoutSubtreeIfNeeded()
  }

  /// グラフの見出し（境目の当たりの 11 下）にポインタを乗せる。
  private static func hoverGraphHeader(in pane: EditorPaneView) {
    guard let handle = view(ScmSplitHandleView.self, in: pane), let window = handle.window else {
      return
    }
    let point = handle.convert(
      NSPoint(x: handle.bounds.midX, y: handle.bounds.midY - Theme.Layout.editorScmRow / 2),
      to: nil)
    pane.sideHost.mouseEntered(with: .mouse(.mouseMoved, at: point, in: window))
    pane.sideHost.mouseMoved(with: .mouse(.mouseMoved, at: point, in: window))
  }

  private static func view<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
    (root as? T) ?? root.subviews.lazy.compactMap { view(type, in: $0) }.first
  }
}
