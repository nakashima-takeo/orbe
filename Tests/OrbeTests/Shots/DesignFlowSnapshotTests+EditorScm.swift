import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ソース管理パネルの flow（fixture は `ScmFixtures`——本物の git の場。状態は本物の操作が生む）:
/// 初期状態（ステージ済み 1・変更 3・未 push 3 と origin 2 のグラフ、変更の行を選ぶ）→ 子の区分を畳む → 端末でコミットして
/// 変更なし（「変更なし」の一言とグラフ・同期 ↑N ↓M）→ push して先行も遅れも無い（数の無い同期）→ upstream の無いブランチ
/// （ブランチを公開）→ git 管理外。実行中の札・失敗の札・破棄の確認は、窓に付けた面の中で撮る `testEditorScmActions`。
extension DesignFlowSnapshotTests {
  func testEditorScm() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "行・グラフ・HEAD の push 済みが揃う")
    var shown = AnyView(scene.view)
    let plain = try plainScene(queriesRoot: queriesRoot)
    defer { plain.cleanup() }
    let panel = scene.panel
    try flow(
      "editor_scm", size: NSSize(width: 1100, height: 640), render: { shown },
      until: { panel.isHeadPushed != nil || panel.branch?.commit == nil },
      steps: panelSteps(scene) + branchSteps(scene) + [
        ("not_managed", { shown = AnyView(plain.view) })
      ])
  }

  /// 初期状態・子の区分を畳む（コミットのポップアップは、窓に付けた面の中で撮る `testEditorScmCommit`）。
  private func panelSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    return [
      (
        "open",
        {
          panel.click(ScmRowID(section: .changes, path: "src/agent/StateHooks.swift"))
          pumpMain(until: { scene.pane.showsDiff(of: "src/agent/StateHooks.swift") }, "押した行の diff")
        }
      ),
      (
        "collapsed",
        {
          panel.toggle(.staged)
          pumpMain(until: { panel.layout.items.count == 5 }, "畳んだ行の組")
        }
      ),
    ]
  }

  /// 本物の git の操作で作るブランチの姿——同期・先行も遅れも無い・公開。
  private func branchSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    let control = panel.control
    let git = scene.git
    return [
      (
        "sync",
        {
          try? git(["branch", "--set-upstream-to=origin/main"])
          try? git(["add", "-A"])
          try? git(["commit", "-qm", "README: 畳んでから渡す"])
          control.message = ""
          pumpMain(
            until: { panel.changes.count == 0 && panel.syncState?.action != .sync(nil) },
            "変更なしで同期のボタン")
        }
      ),
      (
        "idle",
        {
          try? git(["push", "-q", "origin", "HEAD:main"])
          pumpMain(
            until: { panel.syncState?.action == .sync(nil) && panel.isHeadPushed == true },
            "先行も遅れも無い")
        }
      ),
      (
        "publish",
        {
          try? git(["switch", "-q", "-c", "feat/publish"])
          pumpMain(until: { panel.syncState?.action == .publish }, "公開のボタン")
        }
      ),
    ]
  }

  /// git 管理外のフォルダの面（ソース管理のパネルを出す）。
  private func plainScene(queriesRoot: URL) throws -> ScmPlainScene {
    let dir = TestScratch.caseDir.appendingPathComponent("orbe-scm-plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("plain\n".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    return ScmPlainScene(directory: dir, queriesRoot: queriesRoot)
  }
}

/// git 管理外の根の面。
@MainActor
private final class ScmPlainScene {
  private let tab: TerminalTab
  private var warmWindow: NSWindow?
  var pane: EditorPaneView { tab.group.view.editor }

  init(directory: URL, queriesRoot: URL) {
    let group = TabGroup(
      key: GitWorktreeRoot.root(of: directory.path),
      editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot, language: { .ja }))
    tab = TerminalTab(cwd: directory.path, group: group)
    group.view.add(terminal: tab.terminal)
    group.view.show(terminal: tab.terminal)
    group.editor.selectScreen(.changes)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    warmWindow = window
  }

  var view: some View { PlainPane(pane: pane) }

  func cleanup() {
    warmWindow = nil
    pane.removeFromSuperview()
  }

  private struct PlainPane: NSViewRepresentable {
    let pane: EditorPaneView
    func makeNSView(context: Context) -> EditorPaneView { pane }
    func updateNSView(_ view: EditorPaneView, context: Context) {}
  }
}
