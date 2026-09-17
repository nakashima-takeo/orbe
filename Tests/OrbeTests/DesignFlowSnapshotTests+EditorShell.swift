import SwiftUI
import XCTest

@testable import Orbe

/// 骨込みのエディター面の flow（fixture は gallery と同じ `EditorShellFixtures`。状態は本物の操作が生む）。
/// design-system §5 の Rail / Explorer / File tabs が名指しする状態——サイドバー閉（レールに印なし）・行内の
/// 新規入力（続けて押しても 1 行）・ファイルタブの衝突ドット（黄）・文書 0 の骨込み空状態——と、狭い列の
/// 切り詰め中のドラッグ、深い行の可視位置への送りを撮る。
extension DesignFlowSnapshotTests {
  private func editorScene() throws -> EditorShellFixtures.Scene {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot)
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    return scene
  }

  func testEditorShell() throws {
    let scene = try editorScene()
    let pane = scene.pane
    let tab = scene.tab
    let readme = try XCTUnwrap(
      tab.editor.documents.first { $0.url.lastPathComponent == "README.md" })
    try flow(
      "editor_shell", size: NSSize(width: 1100, height: 640), render: { scene.view },
      steps: [
        ("open", {}),
        ("sidebar_closed", { pane.shell.toggleSidebar() }),  // レールに選択印が無い
        ("sidebar_open", { pane.shell.toggleSidebar() }),
        ("new_file_input", { pane.shell.createFile() }),  // 選択（FileTree.swift）の親の子の先頭
        ("new_folder_input", { pane.shell.createDirectory() }),  // 続けて押す → 入力行は 1 つだけ
        (
          "input_cancelled",
          { if let entry = pane.tree.newEntry { pane.tree.cancelNew(entry.generation) } }
        ),
        (
          "conflict_dot",
          {  // 未保存の README をディスク側で書き換える → タブのドットが黄
            try? "outside\n".write(to: readme.url, atomically: true, encoding: .utf8)
            pumpMain(until: { readme.isDiskChanged }, "外部変更の印")
          }
        ),
        ("empty", { for document in tab.editor.documents { tab.editor.close(document) } }),
      ])
  }

  /// 幅 360 の列: サイドバーは 162 に切り詰まり、境を引くと描かれている境から追従する（上限へ押し付けても
  /// 記憶 240 は変わらず、左へ引けば 160 で止まる）。
  func testEditorShellNarrowDrag() throws {
    let scene = try editorScene()
    let pane = scene.pane
    try flow(
      "editor_shell_narrow", size: NSSize(width: 360, height: 480), render: { scene.view },
      steps: [
        ("trimmed", {}),
        ("drag_right_clamped", { pane.resizeSidebar(to: pane.shownSidebarWidth + 40) }),
        ("drag_left", { pane.resizeSidebar(to: pane.shownSidebarWidth - 2) }),
      ])
    XCTAssertEqual(pane.sidebar.width, 160)
  }

  /// 低い窓: 浅い文書から深い文書へ切り替えるとツリーがその行まで送り、新規入力の行も可視位置に生まれる。
  /// 撮り直しのたびに面を別の窓へ載せ替えると ScrollView の位置が戻るので、この flow だけは面を付けた窓の
  /// 中でそのまま描く（操作 → 描画の順は `flow` と同じ）。
  func testEditorShellReveal() throws {
    let scene = try editorScene()
    let pane = scene.pane
    let tab = scene.tab
    let shallow = try XCTUnwrap(
      tab.editor.documents.first { $0.url.lastPathComponent == "tokens.json" })
    let deep = try XCTUnwrap(
      tab.editor.documents.first { $0.url.lastPathComponent == "FileTree.swift" })
    scene.warmUp(size: NSSize(width: 1100, height: 240))
    pane.window?.appearance = NSAppearance(named: .darkAqua)
    let steps: [(label: String, action: () -> Void)] = [
      ("shallow_active", { tab.editor.activate(shallow) }),
      ("deep_active", { tab.editor.activate(deep) }),  // 選択行（深さ 4）が可視位置へ
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
