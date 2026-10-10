import AppKit
import XCTest

@testable import Orbe

/// window レベルの tab 非依存 chrome コマンド配信（`handleWindowKeyCommand`）の overlay／改名編集ガードと、
/// タブ行の「＋」の行き先と、タブのインライン改名（Cmd+R）の確定/取消セマンティクスを固定する。0タブでも届く window コマンドが、
/// パレット/フォーム表示中・改名編集中には暴発しない（＝入力を横取りしない）契約。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerWindowCommandTests: OrbeTestCase {

  /// 単一 leaf タブを持つ workspace をディスクへ書いてから復元済み WindowController を返す。
  private func restoreSingleTab() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    // preferredLanguage を確定させ、初回言語選択 overlay（languageSelect）で overlay==.none の前提が
    // 崩れないようにする（returning user 化）。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return WindowController()
  }

  /// overlay 非表示なら window コマンドを消費（true）し、実際に dispatch する（＝⌘T で worktree パレットが開く）。
  func testWindowKeyCommandDispatchesWhenNoOverlay() throws {
    let wc = try restoreSingleTab()
    XCTAssertEqual(wc.presentedOverlay, .none, "前提: overlay 非表示")
    XCTAssertTrue(
      wc.handleWindowKeyCommand(.showWorktreePalette), "overlay 非表示なら横取りして true を返す")
    XCTAssertEqual(wc.presentedOverlay, .worktreePalette, "⌘T が dispatch され worktree パレットが開く")
  }

  /// タブ行の「＋」は ⌘T と同じ worktree パレットを開き、素のシェルのタブを足さない（入口は 1 つ）。
  func testPlusButtonOpensTheWorktreePaletteWithoutAddingATab() throws {
    let wc = try restoreSingleTab()
    let before = wc.current.tabs.count

    wc.statusModel.onNewTab()

    XCTAssertEqual(wc.presentedOverlay, .worktreePalette)
    XCTAssertEqual(wc.current.tabs.count, before, "素のシェルのタブは開かない")
  }

  /// タブ名の変更中に「＋」や Attention ストリップでパレットを開くと、改名欄の blur（改名の取消）が
  /// パレットより後に届きうる。そのときも焦点は、改名していないときに開いたのと同じパレットの受け手に
  /// 残り、打鍵が端末へ流れない。
  ///
  /// 焦点は SwiftUI の描画を経て次の回以降に移るので、各段は経過時間ではなく焦点が移ったことを待つ。
  func testRenameBlurAfterOpeningAPaletteLeavesFocusOnThePalette() throws {
    let openers = [
      PaletteOpener(
        name: "＋", overlay: .worktreePalette, receiver: { $0 is NSTextView },
        open: { $0.statusModel.onNewTab() }),
      PaletteOpener(
        name: "Attention", overlay: .attentionPalette, receiver: { $0 is ChromeHostingView },
        open: { $0.statusModel.onAttentionTap() }),
    ]
    for opener in openers {
      let name = opener.name
      let wc = try restoreSingleTab()
      let responder = { wc.window.firstResponder }
      XCTAssertTrue(waitUntil { responder() is SurfaceView }, "前提: \(name) 起動直後は端末が焦点を持つ")
      opener.open(wc)
      XCTAssertTrue(
        waitUntil { opener.receiver(responder()) },
        "前提: \(name) 改名していないときは、パレットの受け手が焦点を持つ（実際: \(String(describing: responder()))）")
      wc.dismissPalette()
      XCTAssertTrue(waitUntil { responder() is SurfaceView }, "前提: \(name) 閉じると端末へ戻る")

      wc.beginTabRename()
      XCTAssertTrue(waitUntil { responder() is NSTextView }, "前提: \(name) 改名欄が焦点を持つ")
      let renameField = (responder() as? NSTextView)?.delegate.map(ObjectIdentifier.init)
      opener.open(wc)
      XCTAssertEqual(wc.presentedOverlay, opener.overlay, "前提: \(name) でパレットが開いた")
      let onPalette = {
        opener.receiver(responder())
          && (responder() as? NSTextView)?.delegate.map(ObjectIdentifier.init) != renameField
      }
      XCTAssertTrue(waitUntil { onPalette() }, "前提: \(name) パレットが焦点を取った")
      wc.statusModel.onCancelRename()

      XCTAssertTrue(
        waitUntil { onPalette() },
        "\(name): 改名していないときと同じパレットの受け手が焦点を持つ（実際: \(String(describing: responder()))）")
      XCTAssertFalse(responder() is SurfaceView, "\(name): 焦点が端末へ戻らない")
      wc.dismissPalette()
    }
  }

  /// overlay（パレット/フォーム）表示中は window コマンドを横取りせず false を返し、dispatch もしない。
  /// パレット入力中の ⌘T 等の暴発を防ぐ（キーは subtree/keyDown へ流れる）。
  func testWindowKeyCommandInertWhileOverlayShowing() throws {
    let wc = try restoreSingleTab()
    wc.showWorkspaceCreate(name: nil)  // overlay を .workspaceCreate に立てる
    XCTAssertNotEqual(wc.presentedOverlay, .none, "前提: overlay 表示中")
    XCTAssertFalse(
      wc.handleWindowKeyCommand(.showWorktreePalette), "overlay 表示中は横取りせず false を返す")
    XCTAssertEqual(wc.presentedOverlay, .workspaceCreate, "⌘T は dispatch されない（暴発防止）")
  }

  /// インライン改名（Cmd+R）は overlay を出さないが、編集中は window コマンドを横取りせず false を返す。
  /// 旧実装で `overlay == .tabRename` が守っていた暴発防止が、新設の `editingIndex == nil` ガードへ
  /// 移った分岐を固定する（overlay 版と対の非対称を埋める）。
  func testWindowKeyCommandInertWhileRenaming() throws {
    let wc = try restoreSingleTab()
    wc.beginTabRename()  // editingIndex を立てる（overlay は .none のまま）
    XCTAssertEqual(wc.presentedOverlay, .none, "前提: 改名は overlay を出さない")
    XCTAssertNotNil(wc.statusModel.editingIndex, "前提: 改名編集中")
    XCTAssertFalse(
      wc.handleWindowKeyCommand(.showWorktreePalette), "改名編集中は横取りせず false を返す")
    XCTAssertEqual(wc.presentedOverlay, .none, "⌘T は dispatch されない（暴発防止）")
  }

  /// ⌘⌘（Attention パレット）はヘルプと、差し替えてはならない画面（言語選択・オンボーディング・更新内容）の間は
  /// no-op。ヘルプは押下を点灯・行ハイライトにしか使わない場で、そこに ⌘⌘ が載る以上必ず試し押しされる——効いて
  /// しまうとヘルプ自体が消える。他パレット表示中は従来どおり差し替える（パレット同士の遷移規約）。
  func testAttentionToggleInertWhileHelpOrModalShowing() throws {
    let wc = try restoreSingleTab()
    for overlay in [AppShellModel.Overlay.languageSelect, .onboarding, .updateChanges] {
      wc.model.overlay = overlay
      wc.toggleAttentionPalette()
      XCTAssertEqual(wc.presentedOverlay, overlay, "\(overlay) の間の ⌘⌘ は no-op")
    }
    wc.model.overlay = .none

    wc.showHelp()
    XCTAssertEqual(wc.presentedOverlay, .help, "前提: ヘルプ表示中")
    wc.toggleAttentionPalette()
    XCTAssertEqual(wc.presentedOverlay, .help, "ヘルプ表示中の ⌘⌘ は no-op（ヘルプが残る）")

    wc.dismissHelp()
    wc.showWorkspacePalette()
    wc.toggleAttentionPalette()
    XCTAssertEqual(wc.presentedOverlay, .attentionPalette, "他パレット表示中は差し替わる")
    wc.toggleAttentionPalette()
    XCTAssertEqual(wc.presentedOverlay, .none, "再打鍵で閉じる（トグル）")
  }

  /// `beginTabRename` が編集状態を立てる: editingIndex＝active・editingText＝現在の表示名・focusToken 前進。
  func testBeginTabRenameSeedsEditingState() throws {
    let wc = try restoreSingleTab()
    let token = wc.statusModel.editFocusToken
    let display = wc.current.tabs[0].displayTitle(workspaceRoot: wc.current.rootPath)
    wc.beginTabRename()
    XCTAssertEqual(wc.statusModel.editingIndex, wc.current.active, "編集 index は active タブ")
    XCTAssertEqual(wc.statusModel.editingText, display, "編集テキストは現在の表示名でプリフィル")
    XCTAssertEqual(wc.statusModel.editFocusToken, token &+ 1, "focus トークンが前進")
  }

  /// 確定は前後空白を trim して `explicitTitle` に載せ、編集を畳む（editingIndex を nil に）。
  func testCommitRenameTrimsAndClearsEditing() throws {
    let wc = try restoreSingleTab()
    wc.beginTabRename()
    wc.statusModel.onCommitRename("  Build  ")
    XCTAssertEqual(wc.current.tabs[0].explicitTitle, "Build", "前後空白は trim して確定")
    XCTAssertNil(wc.statusModel.editingIndex, "確定で編集を畳む")
  }

  /// 空（空白のみ）確定は明示名を解除し派生名②③へ戻す（`explicitTitle = nil`）。
  func testCommitEmptyRenameClearsExplicitTitle() throws {
    let wc = try restoreSingleTab()
    wc.current.tabs[0].explicitTitle = "Old"
    wc.beginTabRename()
    wc.statusModel.onCommitRename("   ")
    XCTAssertNil(wc.current.tabs[0].explicitTitle, "空確定は明示名を解除（派生名へ戻す）")
    XCTAssertNil(wc.statusModel.editingIndex, "確定で編集を畳む")
  }

  /// 取消は編集を畳むだけで明示名は変えない。
  func testCancelRenameClearsEditingOnly() throws {
    let wc = try restoreSingleTab()
    wc.current.tabs[0].explicitTitle = "Keep"
    wc.beginTabRename()
    wc.statusModel.onCancelRename()
    XCTAssertNil(wc.statusModel.editingIndex, "取消で編集を畳む")
    XCTAssertEqual(wc.current.tabs[0].explicitTitle, "Keep", "取消は明示名を変えない")
  }

  /// 改名中に押されうる、パレットを開く入口。
  private struct PaletteOpener {
    let name: String
    let overlay: AppShellModel.Overlay
    /// 開いたパレットが焦点を渡す受け手（入力欄を持つパレットは field editor、持たないものは SwiftUI の器）。
    let receiver: (NSResponder?) -> Bool
    let open: (WindowController) -> Void
  }
}
