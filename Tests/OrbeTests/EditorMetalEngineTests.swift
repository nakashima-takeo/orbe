import AppKit
import Metal
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 新しいテキスト面（Metal）を選んだタブで、エディター面の今の働き——開く・切り替える・閉じる・再起動の復元・
/// スクロールバーからのスクロール・⌘F の次でのスクロール・プロジェクト検索の一致を開く・ホイールの量と見えている範囲・
/// 本文の Esc——が今の面と同じように動く。壊れると設定を真にした人の文書が開かない・俯瞰で動かない・一致が見えない・
/// 検索パネルから押した一致が選ばれず中央に来ない・復元で今の面に戻る・ホイールで送る量やミニマップの見えている枠が
/// 今の面と違う・Esc で検索のバーが閉じない。
@MainActor
final class EditorMetalEngineTests: OrbeTestCase {
  private let metal = EditorEngineChoice(
    metal: true, elasticScroll: true, fontSmoothing: true, language: .ja)

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal の装置が無い環境では今の面で開く")
  }

  private var surfaces: EditorSurfaces {
    let choice = metal
    return EditorSurfaces(queriesRoot: nil, engine: { choice })
  }

  private func isMetal(_ document: EditorDocument) -> Bool {
    String(describing: type(of: document.surface)) == "MetalTextSurface"
  }

  private func lines(_ count: Int) -> String {
    (0..<count).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
  }

  func testOpensSwitchesAndClosesWithTheNewSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let a = try tab.editor.open(try caseFile("a.swift", lines(400)))
    let b = try tab.editor.open(try caseFile("b.swift", lines(10)))
    XCTAssertTrue(isMetal(a) && isMetal(b))
    tab.editor.activate(a)
    tab.view.editor.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(a.surface.viewport.visibleLines, 0, "焦点の文書の面が本体に載って大きさを持つ")
    tab.editor.close(b)
    XCTAssertEqual(tab.editor.documents.count, 1)
  }

  /// スクロールバーのトラックを押すとその場で本文が動き、⌘F の次は一致の行を中央に見せる。
  func testOverviewAndFindScrollTheNewSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(2000)))
    XCTAssertTrue(isMetal(document))
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    let bar = pane.scrollbar
    bar.mouseDown(
      with: bar.mouseEvent(.leftMouseDown, at: NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 20))
    )
    bar.mouseUp(
      with: bar.mouseEvent(.leftMouseUp, at: NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 20)))
    XCTAssertGreaterThan(document.viewportLines.first, 1_000, "トラックを押した位置へ飛ぶ")

    pane.showSearch()
    pane.search.setNeedle("value1500 ")
    XCTAssertTrue(document.waitUntilCaughtUp())
    pane.search.next()
    let (first, visible) = document.viewportLines
    XCTAssertEqual(first + visible / 2, 1500.5, accuracy: 1, "一致の行を中央に見せる")
    pane.closeSearch()
  }

  /// プロジェクト検索の一致を押すと、新しい面で開いて一致を選び、その行を中央に見せ、一致の地と現在の一致が俯瞰に出る。
  /// 端末は載せない——shell の cwd の報告が検索の根を動かさない。
  func testProjectSearchOpensAndCentersTheMatchInTheNewSurface() throws {
    let repo = try TempGitRepo(name: "orbe-metal-search")
    defer { repo.cleanup() }
    let content = lines(2000)
    try repo.write("a.swift", content)
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: surfaces)
    let pane = tab.view.editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    defer { window.contentView = nil }
    pane.layoutSubtreeIfNeeded()
    let search = pane.projectSearch
    pane.showProjectSearch(seed: nil)
    search.setPattern("value1500 ")
    search.search()
    pumpMain(until: { search.phase == .done }, "検索が終わる")

    search.click(ProjectSearch.RowID(path: "a.swift", match: 0))

    let document = try XCTUnwrap(pane.document)
    XCTAssertTrue(isMetal(document))
    let match = (content as NSString).range(of: "value1500 ")
    XCTAssertEqual(document.surface.selectedRange, match, "一致を選ぶ")
    let (first, visible) = document.viewportLines
    XCTAssertEqual(first + visible / 2, 1500.5, accuracy: 1, "一致の行を中央に見せる")
    XCTAssertEqual(pane.findGround.matches, [match])
    XCTAssertEqual(pane.findGround.current, [match])
    XCTAssertEqual(pane.scrollbar.decorations.findMatches, [match], "一致の地が俯瞰に出る")
    XCTAssertEqual(pane.scrollbar.decorations.currentFindMatch, match)
  }

  /// 同じ大きさに載せた今の面と新しい面で、同じ中身の文書を開く（窓はテストの終わりに外す）。
  private func openBoth() throws -> (current: EditorDocument, new: EditorDocument) {
    func open(_ engine: EditorEngineChoice) throws -> EditorDocument {
      let tab = TerminalTab(
        cwd: try XCTUnwrap(TestIsolation.caseDir).path,
        editorSurfaces: EditorSurfaces(queriesRoot: nil, engine: { engine }))
      let window = hostEditor(tab, width: 900, height: 500)
      addTeardownBlock { MainActor.assumeIsolated { window.contentView = nil } }
      let document = try tab.editor.open(try caseFile(UUID().uuidString + ".swift", lines(400)))
      tab.view.editor.layoutSubtreeIfNeeded()
      return document
    }
    let current = try open(.stTextView)
    let new = try open(metal)
    XCTAssertTrue(!isMetal(current) && isMetal(new), "前提: 今の面と新しい面")
    return (current, new)
  }

  /// マウスのホイールの 1 目盛りで送る量が、今の面（NSScrollView の行送り）と同じ。今の面はアニメーションで送り、窓を
  /// 画面に出さないテストでは進み方が定まらないので、今の面の側は行送りの値で見る。
  func testWheelNotchMatchesTheCurrentSurface() throws {
    let (current, new) = try openBoth()
    let lineScroll = try XCTUnwrap(
      current.surface.view.subviews.first as? NSScrollView, "前提: 今の面は NSScrollView で送る"
    ).verticalLineScroll
    for notches: Int32 in [1, 3] {
      new.scroll(toFirstLine: 0)
      let event = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -notches, wheel2: 0,
          wheel3: 0))
      new.surface.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
      XCTAssertEqual(
        new.viewportLines.first * EditorStyle.make().lineHeight, lineScroll * CGFloat(notches),
        accuracy: 1e-6,
        "\(notches) 目盛り")
    }
  }

  /// 見えている範囲の値（行・隠れている割合・可視行数・右に続くか・桁）が、同じ位置へ送った今の面と同じ。
  func testViewportMatchesTheCurrentSurface() throws {
    let (current, new) = try openBoth()
    for line: CGFloat in [0.5, 137.25] {
      for document in [current, new] { document.scroll(toFirstLine: line) }
      pumpMain(
        until: { abs(current.viewportLines.first - line) < 1e-6 }, "前提: 今の面が \(line) 行目へ送られた")
      let a = current.surface.viewport
      let b = new.surface.viewport
      XCTAssertEqual(b.firstVisible, a.firstVisible)
      XCTAssertEqual(b.hiddenFraction, a.hiddenFraction, accuracy: 1e-6)
      XCTAssertEqual(b.visibleLines, a.visibleLines, accuracy: 1e-6)
      XCTAssertEqual(b.clipsRight, a.clipsRight)
      XCTAssertEqual(b.hiddenColumns, a.hiddenColumns, accuracy: 1e-6)
      XCTAssertEqual(b.visibleColumns, a.visibleColumns, accuracy: 1e-6)
    }
  }

  /// 新しい面の本文に焦点がある間の Esc も、⌘F のバーを閉じる（今の面と同じ）。
  func testEscapeInTheNewSurfaceClosesTheFindBar() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(10)))
    XCTAssertTrue(isMetal(document))
    let pane = tab.view.editor
    pane.showSearch()
    XCTAssertNotNil(pane.searchBar, "前提: バーが出ている")
    window.makeFirstResponder(document.surface.responder)
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    window.sendEvent(escape)
    XCTAssertNil(pane.searchBar, "閉じる")
    XCTAssertTrue(window.firstResponder === document.surface.responder, "焦点は本文のまま")
  }

  /// 新しい面は 1 回の操作の編集を束で文書へ渡す。検索の一致は、その束（複数行の字下げ）とその undo を編集ごとに畳んで、
  /// 取り直しを待たずに本文の一致の位置に付いていく。壊れると、字下げや ⌘Z の後に一致の地が本文とずれて見える。
  func testSearchMatchesFollowTheBatchesOfTheNewSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(30)))
    XCTAssertTrue(isMetal(document))
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    pane.showSearch()
    pane.search.setNeedle("value")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(pane.search.matches.count, 30, "前提")
    pane.search.refreshDelay.schedule = { _, _ in }
    let responder = document.surface.responder
    responder.selectAll(nil)
    responder.insertTab(nil)
    let text = { document.text.substring(NSRange(location: 0, length: document.text.length)) }
    XCTAssertTrue(text().hasPrefix("    let value0"), "前提: 各行を字下げした")
    XCTAssertEqual(pane.search.matches, occurrences(of: "value", in: text()))
    try XCTUnwrap(responder.undoManager).undo()
    XCTAssertEqual(text(), lines(30), "前提: 戻した")
    XCTAssertEqual(pane.search.matches, occurrences(of: "value", in: text()))
  }

  private func occurrences(of needle: String, in text: String) -> [NSRange] {
    let text = text as NSString
    var found: [NSRange] = []
    var from = 0
    while case let range = text.range(
      of: needle, range: NSRange(location: from, length: text.length - from)),
      range.location != NSNotFound
    {
      found.append(range)
      from = NSMaxRange(range)
    }
    return found
  }

  /// 再起動の復元で開く文書も、タブに渡した組成（新しい面）で開く。
  func testRestoredDocumentsOpenWithTheNewSurface() throws {
    let url = try caseFile("a.swift", lines(5))
    let state = TabState(
      cwd: "/tmp", agent: nil, explicitTitle: nil,
      editor: EditorState(documents: .init(open: [url.path], active: url.path)))
    let tab = TerminalTab(restoring: state, resumeSpawn: { _ in nil }, editorSurfaces: surfaces)
    tab.recordMaterializationStarted()
    XCTAssertTrue(isMetal(try XCTUnwrap(tab.editor.activeDocument)))
  }

  /// 設定から面の選択までの本番の配線——`editor-engine-metal` を真にして実効設定を反映すると、新しいタブで開く文書も
  /// 再起動の復元で開く文書も新しい面になり、偽に戻して開けば今の面になる。壊れると、設定を真にしても全テストが
  /// 緑のまま今の面で開く（タブへ渡す組成が落ちても既定の組成でコンパイルが通る）。
  func testTheSettingPicksTheSurfaceThroughTheWindowController() throws {
    let a = try caseFile("a.swift", lines(5))
    let b = try caseFile("b.swift", lines(5))
    let wc = WindowController()
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.editorEngineMetal, true))
    wc.applyActiveWorkspaceConfig()
    let opened = try XCTUnwrap(
      wc.openTab(workspaceIndex: 0, cwd: a.deletingLastPathComponent().path))
    let tab = try XCTUnwrap(wc.controlResolveTab(opened.tabId))
    XCTAssertTrue(isMetal(try tab.editor.open(a)), "新しいタブで開く文書は新しい面")
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.editorEngineMetal, false))
    wc.applyActiveWorkspaceConfig()
    XCTAssertFalse(isMetal(try tab.editor.open(b)), "偽に戻して開けば今の面")
    XCTAssertTrue(
      isMetal(try XCTUnwrap(tab.editor.documents.first { $0.url == a })), "開いている文書の面は作り直さない")

    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.editorEngineMetal, true))
    let state = TabState(
      cwd: "/tmp", agent: nil, explicitTitle: nil,
      editor: EditorState(documents: .init(open: [a.path], active: a.path)))
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [state])])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let restored = try XCTUnwrap(WindowController().activeTab)
    restored.recordMaterializationStarted()
    XCTAssertTrue(isMetal(try XCTUnwrap(restored.editor.activeDocument)), "復元で開く文書も新しい面")
  }
}
