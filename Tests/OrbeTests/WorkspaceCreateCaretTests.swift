import AppKit
import XCTest

@testable import Orbe

/// 作成フォームの欄へキーボードやフォームの操作で入ったときの選択を、実 `WindowController` の窓の field editor で固定する。
///
/// 壊れると何が起きるか: 開いた直後のパス欄 `~` が全選択になり、続けて `/github` と打つと `~` が消えて
/// `/github` になる。補完の確定や ⇥ で移った先でも同じで、続きを打つたびにキャレットを末尾へ戻す手間が生まれる。
/// 逆に名前欄まで末尾になると、打ち直したい名前を毎回消すことになる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WorkspaceCreateCaretTests: OrbeTestCase {
  private var opened: WindowController?

  override func tearDown() {
    opened?.window.orderOut(nil)
    opened = nil
    super.tearDown()
  }

  /// ホームと別の cwd のタブを持つ主窓で、作成フォームを開いた状態。
  private func openCreateForm() throws -> (WindowController, WorkspaceCreateModel) {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    opened = wc
    // 非アクティブなアプリの窓は key にならないが、`NSApp.sendEvent` は ordered-in の窓の first responder へ届ける。
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
    wc.showWorkspaceCreate(name: nil)
    pump(0.6)
    return (wc, try XCTUnwrap(wc.model.workspaceCreate))
  }

  private func pump(_ seconds: TimeInterval = 0.3) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  private func tab(_ wc: WindowController, shift: Bool = false) {
    let characters = shift ? "\u{19}" : "\t"
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: 48)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump()
  }

  /// focus のある欄の文字列と選択。
  private func editing(
    _ wc: WindowController, file: StaticString = #filePath, line: UInt = #line
  ) throws -> (text: String, selection: NSRange) {
    let editor = try XCTUnwrap(
      wc.window.firstResponder as? NSTextView, "入力欄に focus がある", file: file, line: line)
    return (editor.string, editor.selectedRange())
  }

  private func assertCaretAtEnd(
    _ wc: WindowController, of text: String, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let state = try editing(wc, file: file, line: line)
    XCTAssertEqual(state.text, text, message, file: file, line: line)
    XCTAssertEqual(
      state.selection, NSRange(location: text.utf16.count, length: 0), message, file: file,
      line: line)
  }

  private func assertAllSelected(
    _ wc: WindowController, of text: String, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let state = try editing(wc, file: file, line: line)
    XCTAssertEqual(state.text, text, message, file: file, line: line)
    XCTAssertEqual(
      state.selection, NSRange(location: 0, length: text.utf16.count), message, file: file,
      line: line)
  }

  /// 開いた直後のパス欄 `~` はキャレットが末尾。⇥ / ⇧⇥ でパス↔名前を巡ると、パスは末尾、名前は全選択で入る。
  func testFolderFieldsCaretOnOpenAndTabCycle() throws {
    let (wc, model) = try openCreateForm()
    try assertCaretAtEnd(wc, of: "~", "開いた直後のパス欄は全選択せず末尾")

    tab(wc)
    try assertAllSelected(wc, of: model.curName, "⇥ で入った名前欄は全選択")
    tab(wc)
    try assertCaretAtEnd(wc, of: "~", "⇥ で巡って戻ったパス欄は末尾")
    tab(wc)
    tab(wc, shift: true)
    try assertCaretAtEnd(wc, of: "~", "名前欄から ⇧⇥ で戻ったパス欄は末尾")
    tab(wc, shift: true)
    try assertAllSelected(wc, of: model.curName, "パス欄から ⇧⇥ で入った名前欄は全選択")
  }

  /// 補完を確定すると、差し替わったパスの末尾にキャレットが来る（focus が入ったまま中身が変わる経路）。
  func testAcceptingSuggestionPutsCaretAtEndOfTheNewPath() throws {
    let (wc, model) = try openCreateForm()
    model.suggestions = [FolderSuggestion(name: "tmp", fullPath: "/private/tmp", isRepo: false)]
    pump()
    tab(wc)
    XCTAssertEqual(model.path, "/private/tmp", "前提: ⇥ で候補を確定した")
    try assertCaretAtEnd(wc, of: "/private/tmp", "確定したパスの末尾")
  }

  /// clone へ切り替えると URL 欄は末尾。⇥ で URL→clone 先→名前→URL、⇧⇥ でその逆に巡り、URL と clone 先は末尾、
  /// 名前は全選択で入る。folder に戻したパス欄も末尾。
  func testCloneFieldsCaretOnSourceSwitchAndTabCycle() throws {
    let (wc, model) = try openCreateForm()
    model.setCloneURL("https://github.com/you/repo.git")
    model.setSource(.clone)
    pump(0.6)
    try assertCaretAtEnd(wc, of: "https://github.com/you/repo.git", "切替で入った URL 欄は末尾")

    tab(wc)
    try assertCaretAtEnd(wc, of: "~", "⇥ で入った clone 先欄は末尾")
    tab(wc)
    try assertAllSelected(wc, of: "repo", "⇥ で入った名前欄は全選択")
    tab(wc)
    try assertCaretAtEnd(wc, of: "https://github.com/you/repo.git", "⇥ で巡って戻った URL 欄は末尾")
    tab(wc, shift: true)
    try assertAllSelected(wc, of: "repo", "⇧⇥ で入った名前欄は全選択")
    tab(wc, shift: true)
    try assertCaretAtEnd(wc, of: "~", "⇧⇥ で入った clone 先欄は末尾")

    model.setSource(.folder)
    pump(0.6)
    try assertCaretAtEnd(wc, of: "~", "folder に戻したパス欄は末尾")
  }
}
