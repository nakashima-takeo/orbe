import AppKit

/// エディターの開閉——見せているものの導出と、開閉の命令（⌘E・⌘⇧F、タブをエディターで見せる操作。制御 API の
/// `open_file`・`open_diff` も通る）。
extension WindowController {
  /// 前面の workspace で見せているもの。選択と `editorShownTab` から導く。焦点の行き先・上段の現在地・見ているタブ・
  /// content の照合がこれを読む。
  enum Presentation {
    case empty
    case board
    case terminal(TerminalTab)
    case editor(TerminalTab)
  }

  var presentation: Presentation {
    switch current.selection {
    case .empty: .empty
    case .board: .board
    case .tab(let tab):
      if tab === editorShownTab { .editor(tab) } else { .terminal(tab) }
    }
  }

  /// chrome の現在地。端末で見せているタブは cwd、エディターで見せているタブはその連が導く値。
  var chromeLocation: TerminalTab.Location? {
    switch presentation {
    case .terminal(let tab): .cwd(tab.cwd)
    case .editor(let tab): tab.group.editorLocation
    case .board, .empty: nil
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
