import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 骨込みのエディター面の flow（fixture は gallery と同じ `EditorShellFixtures`。状態は本物の操作が生む）。
/// design-system §5 の Editor bar / Explorer が名指しする状態——左の列を閉じた姿（本体が全幅）・行内の新規入力（続けて
/// 押しても 1 行）・文書 0 の骨込み空状態——と、狭い面の切り詰め中のドラッグ、深い行の可視位置への送りを撮る。
extension DesignFlowSnapshotTests {
  private func editorScene() throws -> EditorShellFixtures.Scene {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    return scene
  }

  func testEditorShell() throws {
    let scene = try editorScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    let group = scene.group
    try flow(
      "editor_shell", size: NSSize(width: 1100, height: 640), render: { scene.view },
      steps: [
        ("open", {}),
        ("sidebar_closed", { pane.toggleSidebar() }),  // 本体が全幅になる
        ("sidebar_open", { pane.toggleSidebar() }),
        ("new_file_input", { pane.shell.createFile() }),  // 選択（FileTree.swift）の親の子の先頭
        ("new_folder_input", { pane.shell.createDirectory() }),  // 続けて押す → 入力行は 1 つだけ
        (
          "input_cancelled",
          { if let entry = pane.tree.newEntry { pane.tree.cancelNew(entry.generation) } }
        ),
        (
          "empty",
          { for document in group.editor.documents { group.editor.close(document) } }
        ),
      ])
  }

  /// 幅 360 の面: 左の列は 199 に切り詰まり、境を引くと描かれている境から追従する（上限へ押し付けても
  /// 記憶 263 は変わらず、左へ引けば 197 になる）。
  func testEditorShellNarrow() throws {
    let scene = try editorScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    try flow(
      "editor_shell_narrow", size: NSSize(width: 360, height: 480), render: { scene.view },
      steps: [
        ("trimmed", {}),
        ("drag_right_clamped", { pane.resizeSidebar(to: pane.shownSidebarWidth + 40) }),
        ("drag_left", { pane.resizeSidebar(to: pane.shownSidebarWidth - 2) }),
      ])
  }

  /// 低い窓: 浅い文書から深い文書へ切り替えるとツリーがその行まで送り、新規入力の行も可視位置に生まれる。
  /// 撮り直しのたびに面を別の窓へ載せ替えると ScrollView の位置が戻るので、この flow だけは面を付けた窓の
  /// 中でそのまま描く（操作 → 描画の順は `flow` と同じ）。
  func testEditorShellReveal() throws {
    let scene = try editorScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    let group = scene.group
    let shallow = try XCTUnwrap(
      group.editor.documents.first { $0.url.lastPathComponent == "tokens.json" })
    let deep = try XCTUnwrap(
      group.editor.documents.first { $0.url.lastPathComponent == "FileTree.swift" })
    scene.warmUp(size: NSSize(width: 1100, height: 240))
    pane.window?.appearance = NSAppearance(named: .darkAqua)
    let steps: [(label: String, action: () -> Void)] = [
      ("shallow_active", { group.editor.activate(shallow) }),
      ("deep_active", { group.editor.activate(deep) }),  // 選択行（深さ 4）が可視位置へ
      ("new_file_input", { pane.shell.createFile() }),  // 入力行が可視位置に生まれる
    ]
    for (idx, step) in steps.enumerated() {
      step.action()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = previewDir("flows").appendingPathComponent(
        String(format: "editor_shell_reveal_%02d_%@.png", idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}
