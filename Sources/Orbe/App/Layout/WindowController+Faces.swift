import AppKit

/// エディターの開閉——見せているものの導出と、開閉の命令（⌘E・⌘⇧F、タブをエディターで見せる操作。制御 API の
/// `open_file`・`open_diff` も通る）、⌥ だけの長押しの間の透かし。
extension WindowController {
  /// 前面の workspace で見せているもの。選択と `editorShownTab` と ⌥ だけの長押しが成立しているかから導く。焦点の行き先・
  /// 上段の現在地・見ているタブ・content の照合がこれを読む。
  enum Presentation {
    case empty
    case board
    case terminal(TerminalTab)
    case editor(TerminalTab)
    /// エディターで見せているタブを、⌥ だけを押している間、端末で見せている（透かし）。焦点と現在地はエディターのまま。
    case peek(TerminalTab)
  }

  var presentation: Presentation {
    switch current.selection {
    case .empty: .empty
    case .board: .board
    case .tab(let tab):
      if tab !== editorShownTab {
        .terminal(tab)
      } else if optionHold.isHolding {
        .peek(tab)
      } else {
        .editor(tab)
      }
    }
  }

  /// `group` の器の見せ方。見せているものがその連のタブのエディターか透かしならそれ、ほかは端末。
  func facesMode(of group: TabGroup) -> GroupFacesView.Mode {
    switch presentation {
    case .editor(let tab) where tab.group === group: .editor
    case .peek(let tab) where tab.group === group: .peek
    default: .terminal
    }
  }

  /// chrome の現在地。端末で見せているタブは cwd、エディターで見せているタブ（透かしを含む）はその連が導く値。
  var chromeLocation: TerminalTab.Location? {
    switch presentation {
    case .terminal(let tab): .cwd(tab.cwd)
    case .editor(let tab), .peek(let tab): tab.group.editorLocation
    case .board, .empty: nil
    }
  }

  /// ⌥ だけの長押しが成立を許すか: 前面の窓で、オーバーレイ（パレット・ヘルプなど）が出ておらず、タブのエディターを見せている。
  var allowsPeek: Bool {
    guard window.isKeyWindow, model.overlay == .none, case .editor = presentation else {
      return false
    }
    return true
  }

  /// ⌥ だけの長押しが成立した・終わった。選んでいるタブの連の器へ見せ方を動きつきで写し、透かしで端末が見えたタブの done を
  /// 消すだけで、描く関数（`renderSelection`）は通さない（フォーカスを当て直さない）。
  func optionHoldDidChange() {
    switch presentation {
    case .editor(let tab), .peek(let tab):
      tab.group.view.show(facesMode(of: tab.group), animated: true)
      consumeVisibleTabDone()
    case .terminal, .board, .empty:
      break
    }
  }

  /// ⌘E。選んでいるタブのエディターを開く・閉じる（動きつき）。選んでいるタブが無ければ（ボード・空）no-op。
  func toggleEditorFace() {
    guard let tab = activeTab else { return }
    editorShownTab = editorShownTab === tab ? nil : tab
    renderSelection(animated: true)
  }

  /// `tab` をエディターで見せる。既に見せていれば何もしない（描画しない）。別の workspace のタブなら、その workspace へ
  /// 移ってから 1 回だけ描画する。前から選んでいたタブなら開く動きを付け、別のタブへ移るなら即時。
  func showInEditor(_ tab: TerminalTab) {
    guard editorShownTab !== tab else { return }
    let switched = activateWorkspace(of: tab)
    guard current.tabs.contains(where: { $0 === tab }) else { return }
    let inPlace = !switched && activeTab === tab
    store.recordSelection(.tab(tab))
    editorShownTab = tab
    renderSelection(animated: inPlace)
    if switched { finishWorkspaceSwitch() }
  }

  /// ⌘⇧F。選んでいるタブをエディターで見せ、サイドバーを検索パネルで開いて入力欄に焦点を入れる。種は押した時点の焦点で
  /// 決めるので、エディターを開く前に取る。選んでいるタブが無ければ no-op。
  func findInProject() {
    guard let tab = activeTab else { return }
    let pane = tab.group.view.editor
    let seed = pane.projectSearchSeed()
    showInEditor(tab)
    pane.showProjectSearch(seed: seed)
  }
}
