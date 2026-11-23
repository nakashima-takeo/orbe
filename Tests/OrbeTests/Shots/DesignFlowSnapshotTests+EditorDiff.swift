import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の flow（fixture は `EditorDiffFixtures`——本物のコード片の git リポジトリ。開くのは `open_diff` と同じ連の口）。
/// 作業ツリー / ステージ済み × インライン（窓の幅 1100）/ 並列（本体が並列の境の値になる幅）× dark / light、長い行を横に送った状態、削除の多い区間、表示できない一文、
/// 新しいファイル・消したファイル（版が無い側は 0 行。見えている高さより長く消したファイルは削除行の頭から開く）、diff の
/// 中で編集して未保存にした文書がタブ行に残ったまま別の diff へ移った姿を撮る。
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
        ("new_file_inline", { try stage.open("Sources/HookClock.swift", .workingTree) }),
        ("new_file_side", { stage.select(.side) }),
        ("deleted_file_side", { try stage.open("Sources/RetiredHooks.swift", .workingTree) }),
        ("deleted_file_inline", { stage.select(.inline) }),
        (
          "deleted_long_file_inline", { try stage.open("Sources/RetiredTable.swift", .workingTree) }
        ),
        (
          "staged_new_file_side_light",
          {
            stage.window.appearance = NSAppearance(named: .aqua)
            stage.select(.side)
            try stage.open("docs/todo.md", .staged)
          }
        ),
        (
          "dirty_then_other_diff",
          {
            stage.window.appearance = NSAppearance(named: .darkAqua)
            stage.select(.inline)
            try stage.dirtyThenOpenAnother()
          }
        ),
      ])
  }

  private var queriesRoot: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }
}

/// diff の flow の窓と手順。
@MainActor
private final class DiffStage {
  let scene: EditorDiffFixtures.Scene
  let window: NSWindow
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
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState())
    scene.pane.layoutSubtreeIfNeeded()
    let pane = scene.pane
    pumpMain(until: { pane.tree.status != nil }, "git の状態が届く")
  }

  func close() {
    window.contentView = nil
    scene.cleanup()
  }

  /// diff を `open_diff` と同じ連の口で開き（Changes の画面を選び、左の列でその行を選ぶ）、行の選択と、中身・並び・色が揃う
  /// まで待つ。
  @discardableResult
  func open(_ path: String, _ kind: EditorDiff.Kind) throws -> EditorDiff {
    let key = scene.key(path, kind)
    try scene.group.openDiff(key)
    let pane = pane
    pumpMain(until: { pane.scm.selection == pane.scm.rowID(of: key) }, "左の列でその行を選ぶ")
    settle()
    return try XCTUnwrap(pane.diff)
  }

  /// 窓の幅を、本体が見せ方 `mode` になる幅にする（並列なら本体がちょうど境の値、インラインなら 1100）。
  func select(_ mode: EditorDiff.Mode) {
    let width =
      mode == .side
      ? Theme.Layout.editorDiffSideWidth + Theme.Layout.editorSidebar + Theme.Stroke.hairline
      : 1100
    window.setContentSize(NSSize(width: width, height: window.frame.height))
    scene.pane.layoutSubtreeIfNeeded()
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

  /// 作業ツリー diff の中で打って未保存にし、別の行の diff へ移る（未保存の文書はタブ行に未保存の印つきで残る）。
  func dirtyThenOpenAnother() throws {
    let diff = try open("Sources/HookBuffer.swift", .workingTree)
    let document = try XCTUnwrap(diff.document)
    document.surface.responder.perform(Selector(("insertText:")), with: "// ")
    try open("Sources/Legacy.swift", .workingTree)
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
