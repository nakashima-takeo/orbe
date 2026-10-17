import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ソース管理パネルの flow（fixture は `ScmFixtures`——見本 `editor/data.ts` と同じ形の本物の git の場。状態は本物の操作が
/// 生む）: 見本の姿（ステージ済み 1・変更 3・未 push 3 と origin 2 のグラフ、変更の行を選ぶ）→ グラフの見出しを選ぶ（地は
/// 見出しの帯だけ）→ 本文つきのメッセージで欄が伸びる → 区分を畳む（欄が空で主の側が押せない）→ 返らない pre-commit hook の
/// コミットで実行中の帯 → 止める → upstream の無いブランチのプルの失敗の文 → 端末でコミットして変更なし（グラフだけ・同期
/// ↑N ↓M）→ push して先行も遅れも無い（主の側も ▾ も押せない）→ upstream の無いブランチ（ブランチを公開）→ git 管理外。
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
    try flow(
      "editor_scm", size: NSSize(width: 1100, height: 640), render: { shown },
      steps: panelSteps(scene) + gitSteps(scene) + [
        ("not_managed", { shown = AnyView(plain.view) })
      ])
  }

  /// 見本の姿・メッセージ欄が伸びる・区分を畳む。
  private func panelSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    let control = panel.control
    return [
      ("open", { panel.select(ScmRowID(section: .changes, path: "src/agent/StateHooks.swift")) }),
      ("graph_header", { panel.select(ScmRowID(section: .graph, path: nil)) }),
      ("message", { control.message = "StateHooks: emit を畳む\n\n連続する知らせを 1 つにまとめ、\n描画の遅れを減らす。" }),
      (
        "collapsed",
        {
          control.message = ""
          panel.toggle(.staged)
          panel.toggle(.graph)
          pumpMain(until: { panel.layout.items.count == 6 }, "畳んだ行の組")
        }
      ),
    ]
  }

  /// 本物の git の操作で作る状態——実行中の帯と止める・失敗の文・同期・公開。
  private func gitSteps(_ scene: ScmFixtures.Scene) -> [(label: String, action: () -> Void)] {
    let panel = scene.panel
    let control = panel.control
    let git = scene.git
    return [
      (
        "running",
        {
          panel.toggle(.staged)
          panel.toggle(.graph)
          try? Self.hangingHook(in: scene.directory)
          control.message = "wip"
          control.commit()
          pumpMain(until: { control.bandOperation != nil }, "帯が出る")
        }
      ),
      (
        "stopped",
        {
          control.bandOperation?.stop()
          pumpMain(until: { control.operations.isEmpty }, "止めた")
          try? FileManager.default.removeItem(
            at: scene.directory.appendingPathComponent(".git/hooks/pre-commit"))
        }
      ),
      (
        "failure",
        {
          try? git(["branch", "--unset-upstream"])
          pumpMain(until: { panel.branch?.upstream == nil }, "upstream が外れる")
          control.pull()
          pumpMain(until: { control.failure != nil }, "失敗の文")
        }
      ),
      (
        "sync",
        {
          try? git(["branch", "--set-upstream-to=origin/main"])
          try? git(["add", "-A"])
          try? git(["commit", "-qm", "README: 畳んでから渡す"])
          control.message = ""
          pumpMain(
            until: { panel.changes.count == 0 && panel.commitState.primary != .commit },
            "変更なしで同期のボタン")
        }
      ),
      (
        "idle",
        {
          try? git(["push", "-q", "origin", "HEAD:main"])
          pumpMain(
            until: { panel.commitState.primary == .commit && panel.isHeadPushed == true },
            "先行も遅れも無い")
        }
      ),
      (
        "publish",
        {
          try? git(["switch", "-q", "-c", "feat/publish"])
          pumpMain(until: { panel.commitState.primary == .publish }, "公開のボタン")
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

  /// 返らない pre-commit hook（止めるまで待つ。60 秒で自分から抜ける）。
  private static func hangingHook(in directory: URL) throws {
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nsleep 60\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
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
    group.view.editor.selectPanel(.sourceControl)
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
