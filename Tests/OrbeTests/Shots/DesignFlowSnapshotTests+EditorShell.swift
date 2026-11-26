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

  /// 上のバーの 3 つの画面の姿を、幅 1100 から 560 まで狭めていく。部品は譲る順のとおりに譲る——Changes は案内 →
  /// コミットの添え書き → ブランチ名の省略 → ブランチ名の札、PR は案内 →「→ ベース」→ ブランチ名の省略 → PR の札、
  /// Files は案内 → 検索の欄の幅 → 親のパス → 名前の省略。
  func testEditorBarNarrowing() throws {
    var width: CGFloat = 1100
    let steps = [1100, 1000, 900, 800, 700, 640, 600, 560].map { next in
      (label: "w\(next)", action: { width = CGFloat(next) })
    }
    try flow(
      "editor_bar_narrowing", size: NSSize(width: 1100, height: 148),
      render: {
        VStack(alignment: .leading, spacing: 8) {
          ForEach([EditorScreen.changes, .pullRequest, .files], id: \.self) { screen in
            EditorShellFixtures.bar(screen).frame(width: width)
          }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.theme.bgBase)
        .environment(\.localization, LocalizationStore(language: .ja))
      }, steps: steps)
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

/// 開いているファイルの一覧の flow と gallery。一覧の器は面が窓に付いている間だけ開いているので（窓から外れると閉じる）、
/// 面を付けた窓の中でそのまま描く。操作は製品と同じ入口（ボタンの閉包・行の列へのキーと押下・面の ⌘P）から入れる。
extension ShotTestCase {
  func openFilesScene(size: NSSize) throws -> EditorShellFixtures.Scene {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    scene.warmUp(size: size)
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    try scene.openMoreFiles()
    pumpMain(until: { scene.isOpenFilesReady }, "印と状態の字が揃う")
    return scene
  }

  /// 窓に付けた面 `pane` の中で、手順ごとに描いて `<name>_<NN>_<label>[_light].png` を書く。
  func renderInPlace(
    _ pane: EditorPaneView, name: String, dir: URL, appearances: [Bool],
    steps: [(label: String, action: () -> Void)]
  ) throws {
    for (idx, step) in steps.enumerated() {
      step.action()
      for dark in appearances {
        pane.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        pane.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent(
          String(format: "%@_%02d_%@%@.png", name, idx, step.label, dark ? "" : "_light"))
        try data.write(to: url)
        print("[shot] wrote \(url.path)")
      }
    }
  }

  /// 行の列へキーを 1 つ送る（`chars` は NSEvent の文字）。
  func listKey(_ pane: EditorPaneView, _ chars: String) {
    pane.itemList.list.list.keyDown(with: .key(chars, []))
  }

  static func arrow(_ key: NSEvent.SpecialKey) -> String { String(UnicodeScalar(key.rawValue)!) }

  /// 行の列の行 `index` の × を押す。
  func pressMark(_ pane: EditorPaneView, row index: Int) {
    let list = pane.itemList.list.list
    guard
      let slot = list.subviews.compactMap({ $0 as? EditorItemListRowView }).first(where: {
        $0.row == index && !$0.isHidden
      }), let mark = slot.markRect
    else { return XCTFail("行 \(index) が見えていない") }
    list.mouseDown(with: slot.mouseEvent(.leftMouseDown, at: NSPoint(x: mark.midX, y: mark.midY)))
  }
}

extension DesignFlowSnapshotTests {
  /// 置き場のポップアップ（仮の中身）を本物の面で開閉する: 右端のボタンに当たる開閉で開く → 打つ → esc で閉じる → 開く →
  /// ⌘P で一覧を開く（ポップアップは閉じる）→ esc → 開く → 地の外にメニューを並べる → ⌘↵ で閉じる。面を付けた窓の中で
  /// 描く（窓から外れると閉じる）。
  func testEditorDock() throws {
    let size = NSSize(width: 1100, height: 640)
    let scene = try openFilesScene(size: size)
    defer { scene.cleanup() }
    let pane = scene.pane
    let owner = EditorShellFixtures.DockPopupOwner(popup: pane.popup)
    try renderInPlace(
      pane, name: "editor_dock", dir: previewDir("flows"), appearances: [true, false],
      steps: [
        ("open", { pane.popup.toggle(owner) }),
        (
          "typed",
          {
            owner.field.insertText(
              "fix: 置き場の仮の中身", replacementRange: NSRange(location: NSNotFound, length: 0))
          }
        ),
        ("escape", { owner.field.keyDown(with: .key("\u{1b}", [])) }),
        ("reopen", { pane.popup.toggle(owner) }),
        ("item_list", { _ = pane.performKeyEquivalent(with: .key("p")) }),
        ("item_list_closed", { self.listKey(pane, "\u{1b}") }),
        ("reopen_again", { pane.popup.toggle(owner) }),
        ("menu", { owner.showsMenu = true }),
        ("command_return", { _ = pane.performKeyEquivalent(with: .key("\r")) }),
      ])
  }

  /// ボタンを押す → ↓ → ↵ で切り替わる → ⌘P で開く → → で詳細 → ← → × で閉じる → esc。左の列を閉じた姿でも開く。
  func testEditorShellOpenFiles() throws {
    let size = NSSize(width: 1100, height: 640)
    let scene = try openFilesScene(size: size)
    defer { scene.cleanup() }
    let pane = scene.pane
    try renderInPlace(
      pane, name: "editor_shell_open_files", dir: previewDir("flows"), appearances: [true],
      steps: [
        ("button", { pane.shell.toggleItemList() }),
        ("down", { self.listKey(pane, Self.arrow(.downArrow)) }),
        ("enter", { self.listKey(pane, "\r") }),
        ("command_p", { _ = pane.performKeyEquivalent(with: .key("p")) }),
        ("detail", { self.listKey(pane, Self.arrow(.rightArrow)) }),
        ("back", { self.listKey(pane, Self.arrow(.leftArrow)) }),
        ("close_row", { self.pressMark(pane, row: 4) }),
        ("escape", { self.listKey(pane, "\u{1b}") }),
        ("sidebar_closed", { pane.toggleSidebar() }),
        ("sidebar_closed_open", { pane.shell.toggleItemList() }),
      ])
  }
}

extension DesignFlowSnapshotTests {
  /// ツリーの絞り込み: 打つ → 結果（合ったファイルと親のフォルダだけが全部開いた形で残る）→ フォルダを畳む → 字を変える
  /// （全部開いた形に戻る）→ 0 件 → 字を消す（絞り込む前のツリーに戻る）。開いている文書の印も、結果の行に出る。
  func testEditorShellFilter() throws {
    let size = NSSize(width: 1100, height: 640)
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp(size: size)
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let tree = scene.pane.tree
    func filter(_ text: String) {
      tree.setFilterText(text)
      pumpMain(until: { tree.filter.shown?.text == text }, timeout: 10, "「\(text)」の結果が届く")
    }
    try renderInPlace(
      scene.pane, name: "editor_shell_filter", dir: previewDir("flows"),
      appearances: [true, false],
      steps: [
        ("typed", { filter("e") }),
        ("folder_collapsed", { tree.toggle("docs") }),
        ("refined", { filter("ee") }),
        ("no_match", { filter("zzq") }),
        ("cleared", { tree.setFilterText("") }),
      ])
  }
}
