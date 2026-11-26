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

  /// ⌥ 長押しでめくる最上層の 1 枚。Z=2（ブラウザ）が開いていれば常にブラウザのみ、
  /// 閉じていてエディターが開いていればエディターのみ。
  enum PeekTarget: Equatable {
    case browser
    case editor
  }

  var peekTarget: PeekTarget? {
    if browserMode != .closed { return .browser }
    if let tab = activeTab, editorShownTab === tab { return .editor }
    return nil
  }

  /// 最上層のブラウザをめくっているか。
  var browserPeeking: Bool { optionHold.isHolding && peekTarget == .browser }

  /// 全面ブラウザが非めくりで下層全面を覆っているか。
  var browserCoversUnderlay: Bool { browserMode == .full && !browserPeeking }

  /// ブラウザが非めくりでボードを覆っているか（右シートでも詳細欄が覆われるため非めくり時は常に真）。
  var browserCoversBoard: Bool { browserMode.isOpen && !browserPeeking }

  /// 全面ブラウザの Peek ピルへ示す直下の層。
  var browserPeekUnderlay: BrowserPeekUnderlay {
    switch presentation {
    case .editor, .peek: .editor
    case .terminal: .terminal
    case .board: .board
    case .empty: .window
    }
  }

  var presentation: Presentation {
    switch current.selection {
    case .empty: .empty
    case .board: .board
    case .tab(let tab):
      if tab !== editorShownTab {
        .terminal(tab)
      } else if optionHold.isHolding && peekTarget == .editor {
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

  /// 「見ているタブ」＝ウィンドウがキー（前面）のときに、アクティブ workspace で端末が見えているタブ（端末で見せているか、
  /// 透かしている。全面ブラウザが非めくりで覆っている間は除く）。背面・ボード・空・エディターで見せている間・全面ブラウザが
  /// 覆っている間は nil。done のフォーカス消費・メニューバー②の抑制・通知音の抑制が、この 1 つの判定を共有する。
  var visibleTab: TerminalTab? {
    guard window.isKeyWindow else { return nil }
    if browserCoversUnderlay { return nil }
    switch presentation {
    case .terminal(let tab), .peek(let tab): return tab
    case .editor, .board, .empty: return nil
    }
  }

  /// 完了通知の消費：見ているタブの done を消費して done バッジを消す。
  /// 背面・背景タブの done は残す。描画（`renderSelection`）・done 到着・前面復帰・透かしの出入り・ブラウザモード変更が共有する。
  func consumeVisibleTabDone() { visibleTab?.consumeDoneState() }

  /// ⌥ だけの長押しが成立を許すか: 前面の窓で、オーバーレイ（パレット・ヘルプなど）が出ておらず、めくり対象（Z=2 または Z=1）がある。
  var allowsPeek: Bool {
    window.isKeyWindow && model.overlay == .none && peekTarget != nil
  }

  /// ⌥ だけの長押しが成立した・終わった。Z=1・Z=2 の透かし状態と done 消費を単一同期口へ集約し、
  /// `renderSelection` は通さない（フォーカスを当て直さない）。
  func optionHoldDidChange() {
    syncPeekState(animated: true)
  }

  /// Z=1（連の器）と Z=2（ブラウザ層）の透かし状態を現在の `optionHold` / `peekTarget` へ同期し、露出した端末の done を消費する。
  func syncPeekState(animated: Bool) {
    if let tab = activeTab {
      tab.group.view.show(facesMode(of: tab.group), animated: animated)
    }
    browserView.setPeekUnderlay(browserPeekUnderlay)
    browserView.setPeeking(browserPeeking, animated: animated)
    consumeVisibleTabDone()
  }

  /// ⌘E。選んでいるタブのエディターを開く・閉じる（動きつき）。選んでいるタブが無ければ（ボード・空）no-op。
  /// 全面ブラウザ表示中は反転せず全面を閉じてエディターを開き、右シート表示中は右シートを残して下層だけを切り替える。
  func toggleEditorFace() {
    guard let tab = activeTab else { return }
    let wasFull = browserMode == .full
    yieldBrowserToUnderlay(animated: true)
    editorShownTab = wasFull ? tab : (editorShownTab === tab ? nil : tab)
    renderSelection(animated: true)
  }

  /// `tab` を選んでエディターで見せる（別の workspace のタブなら、その workspace へ移る）。既に見せていても全面ブラウザ中または
  /// ブラウザ焦点中なら下層へ引き渡してフォーカスをエディターへ移す。前から選んでいたタブなら開く動きを付け、別のタブへ移るなら即時。
  func showInEditor(_ tab: TerminalTab) {
    let needsYield = browserMode == .full || browserWasFocused || browserView.focusIsInside
    guard editorShownTab !== tab || needsYield, let index = store.workspaceIndex(of: tab) else {
      return
    }
    select(.tab(tab), inWorkspaceAt: index, inEditor: true)
  }

  /// ⌘⇧F。選んでいるタブをエディターで見せ、Files の画面で左の列を検索パネルにして開き、入力欄に焦点を入れる。種は押した時点の焦点で
  /// 決めるので、エディターを開く前に取る。選んでいるタブが無ければ no-op。
  func findInProject() {
    guard let tab = activeTab else { return }
    let pane = tab.group.view.editor
    let seed = pane.projectSearchSeed()
    showInEditor(tab)
    pane.showProjectSearch(seed: seed)
  }
}
