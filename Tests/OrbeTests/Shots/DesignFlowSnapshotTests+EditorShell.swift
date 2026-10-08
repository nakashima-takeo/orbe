import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 骨込みのエディター面の flow（fixture は gallery と同じ `EditorShellFixtures`。状態は本物の操作が生む）。
/// design-system §5 の Rail / Explorer / File tabs が名指しする状態——サイドバー閉（レールに印なし）・行内の
/// 新規入力（続けて押しても 1 行）・ファイルタブの衝突ドット（黄）・ファイルタブの × と ● のポインタによる出し分け・
/// 仮のタブの斜体と斜線の地・文書 0 の骨込み空状態——と、狭い列の切り詰め中のドラッグ、深い行の可視位置への送りを撮る。
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
    let tab = scene.tab
    let readme = try XCTUnwrap(
      tab.editor.documents.first { $0.url.lastPathComponent == "README.md" })
    try flow(
      "editor_shell", size: NSSize(width: 1100, height: 640), render: { scene.view },
      steps: [
        ("open", {}),
        ("sidebar_closed", { pane.shell.selectPanel(.files) }),  // レールに選択印が無い
        ("sidebar_open", { pane.shell.selectPanel(.files) }),
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

  /// ファイルタブの右端の枠: ポインタなし（アクティブは ×・未保存は ●）→ 保存済みのタブの上（× が出る）→ 未保存の
  /// タブの上（● のまま）→ 未保存のタブの ● の上（× に替わり枠に地）→ 保存済みのタブの × の上（枠の地と明るい ×）、
  /// 最後に同じ状態を light で。ホバーは窓の中の面に
  /// 合成のポインタで起こすので、reveal と同じく面を付けた窓の中でそのまま描く。
  func testEditorTabClose() throws {
    let scene = try editorScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    scene.warmUp(size: NSSize(width: 1100, height: 240))
    pane.window?.appearance = NSAppearance(named: .darkAqua)
    let slot = { (index: Int) in self.fileTabSlotCenter(pane, index) }
    let steps: [(label: String, action: () -> Void)] = [
      ("rest", { self.movePointer(pane, to: NSPoint(x: pane.bounds.maxX - 4, y: slot(0).y)) }),
      ("pointer_on_tab", { self.movePointer(pane, to: NSPoint(x: slot(1).x - 30, y: slot(1).y)) }),
      (
        "pointer_on_dirty_tab",
        { self.movePointer(pane, to: NSPoint(x: slot(0).x - 30, y: slot(0).y)) }
      ),
      ("pointer_on_dirty_close", { self.movePointer(pane, to: slot(0)) }),
      ("pointer_on_close", { self.movePointer(pane, to: slot(1)) }),
      ("pointer_on_close_light", { pane.window?.appearance = NSAppearance(named: .aqua) }),
    ]
    for (idx, step) in steps.enumerated() {
      step.action()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = previewDir("flows").appendingPathComponent(
        String(format: "editor_tab_close_%02d_%@.png", idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }

  /// 仮のタブ（名前の斜体と斜線の地）: 見ていないとき → 見ているとき → 日本語名・絵文字入りの名前で入れ替えたとき
  /// （斜体の face が無い字でも斜線の地で見分けられるか）を、dark と light で。reveal と同じく面を付けた窓の中でそのまま描く。
  func testEditorPreviewTab() throws {
    let scene = try editorScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    let editor = scene.tab.editor
    let directory = scene.directory
    let tokens = directory.appendingPathComponent("docs/design/tokens.json")
    let fileTree = try XCTUnwrap(
      editor.documents.first { $0.url.lastPathComponent == "FileTree.swift" })
    let japanese = directory.appendingPathComponent("仮のメモ.md")
    let emoji = directory.appendingPathComponent("🚀 launch notes.md")
    try "# メモ\n".write(to: japanese, atomically: true, encoding: .utf8)
    try "# launch\n".write(to: emoji, atomically: true, encoding: .utf8)
    scene.warmUp(size: NSSize(width: 1100, height: 240))
    var steps: [(label: String, action: () -> Void)] = []
    for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
      steps += [
        (
          "\(name)_inactive",
          {
            pane.window?.appearance = NSAppearance(named: appearance)
            _ = try? editor.open(tokens, as: .preview)
            editor.activate(fileTree)
          }
        ),
        ("\(name)_active", { _ = try? editor.open(tokens, as: .preview) }),
        ("\(name)_japanese", { _ = try? editor.open(japanese, as: .preview) }),
        ("\(name)_emoji", { _ = try? editor.open(emoji, as: .preview) }),
      ]
    }
    for (idx, step) in steps.enumerated() {
      step.action()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = previewDir("flows").appendingPathComponent(
        String(format: "editor_preview_tab_%02d_%@.png", idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}
