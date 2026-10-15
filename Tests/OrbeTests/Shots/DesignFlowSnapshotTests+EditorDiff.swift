import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff のタブの flow（fixture は `EditorDiffFixtures`——本物のコード片の git リポジトリ。開くのは `open_diff` と同じセッション
/// の口）。作業ツリー / ステージ済み × インライン / 並列 × dark / light、長い行を横に送った状態、削除の多い区間、表示できない
/// 一文、仮の diff タブ、未保存の印のある diff タブを撮る。見本は orbe_design の `DiffView.tsx`・`EditorLayer.tsx`。
extension DesignFlowSnapshotTests {
  func testEditorDiff() throws {
    let stage = try DiffStage(queries: queriesRoot)
    defer { stage.close() }
    try stage.shoot(
      "editor_diff", to: previewDir("flows"),
      steps: [
        ("working_inline", { try stage.open("Sources/HookBuffer.swift", .workingTree) }),
        ("working_side", { stage.select(.side) }),
        ("working_side_light", { stage.window.appearance = NSAppearance(named: .aqua) }),
        ("working_inline_light", { stage.select(.inline) }),
        (
          "long_line_scrolled",
          {
            stage.window.appearance = NSAppearance(named: .darkAqua)
            try stage.scrollRight(cells: 60)
          }
        ),
        ("staged_inline", { try stage.open("docs/guide.md", .staged) }),
        ("staged_side", { stage.select(.side) }),
        (
          "many_deletions",
          {
            stage.select(.inline)
            try stage.open("Sources/Legacy.swift", .workingTree)
          }
        ),
        ("not_text", { try stage.open("icon.bin", .staged) }),
        ("preview_and_dirty", { try stage.previewAndDirty() }),
      ])
  }

  private var queriesRoot: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }
}

/// diff の flow の窓と手順。
@MainActor
private final class DiffStage {
  let scene: EditorDiffFixtures.Scene
  let window: NSWindow
  let modes = EditorDiffModeState()
  private var pane: EditorPaneView { scene.pane }

  init(queries: URL) throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    scene = try EditorDiffFixtures.scene(queriesRoot: queries, in: TestScratch.caseDir)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 520), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = scene.pane
    scene.pane.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(), diffModes: modes)
    scene.pane.layoutSubtreeIfNeeded()
    let pane = scene.pane
    pumpMain(until: { pane.tree.status != nil }, "git の状態が届く")
  }

  func close() {
    window.contentView = nil
    scene.cleanup()
  }

  /// diff を開き、中身・並び・色が揃うまで待つ。
  @discardableResult
  func open(_ path: String, _ kind: EditorDiff.Kind, as mode: EditorSession.OpenMode = .pinned)
    throws -> EditorDiff
  {
    let diff = try scene.tab.editor.openDiff(scene.key(path, kind), as: mode)
    settle()
    return diff
  }

  func select(_ mode: EditorDiff.Mode) {
    modes.select(mode)
    let pane = pane
    pumpMain(
      until: { pane.diff.map { pane.diffSurfaces($0).count == (mode == .side ? 2 : 1) } ?? true },
      "見せ方が変わる")
    settle()
  }

  /// 見せている diff の中身・並び・色が揃うまで待つ。
  func settle() {
    let pane = pane
    pumpMain(until: { pane.diff?.content != .loading }, "diff の中身が届く")
    guard let diff = pane.diff else { return }
    diff.old?.waitUntilCaughtUp()
    diff.newRevision?.waitUntilCaughtUp()
    diff.document?.waitUntilCaughtUp()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  }

  func scrollRight(cells: CGFloat) throws {
    let surface = try XCTUnwrap(pane.diff?.newSurface as? MetalTextSurface)
    surface.scroll(toX: cells * surface.config.cell)
    surface.flush()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  }

  /// ファイルタブで打って未保存にし、仮の diff タブを開いてから、未保存の印の付いた作業ツリー diff へ戻る。
  func previewAndDirty() throws {
    let editor = scene.tab.editor
    let document = try editor.open(
      scene.directory.appendingPathComponent("Sources/HookBuffer.swift"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "// ")
    editor.close(.diff(scene.key("Sources/Legacy.swift", .workingTree)))
    try open("Sources/Legacy.swift", .workingTree, as: .preview)
    editor.activate(.diff(scene.key("Sources/HookBuffer.swift", .workingTree)))
    settle()
  }

  /// 手順ごとに本体を撮る（名前と置き場は他の flow と同じ）。
  func shoot(
    _ name: String, to directory: URL, steps: [(label: String, action: () throws -> Void)]
  ) throws {
    for (index, step) in steps.enumerated() {
      try step.action()
      pane.layoutSubtreeIfNeeded()
      for surface in pane.diff.map(pane.diffSurfaces) ?? [] {
        (surface as? MetalTextSurface)?.flush()
      }
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let url = directory.appendingPathComponent(
        String(format: "%@_%02d_%@.png", name, index, step.label))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}
