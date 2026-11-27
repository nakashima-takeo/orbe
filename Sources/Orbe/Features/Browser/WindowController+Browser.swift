import AppKit

/// ウィンドウ単一の内蔵ブラウザ層（Z=2）の配線・開閉・モード切替・フォーカス同期。
extension WindowController {
  static func makeBrowserSession(language: Language) -> BrowserSession {
    MainActor.assumeIsolated {
      let store = BrowserStore(
        opening: BrowserPersistence.open(language: language), language: language)
      return BrowserSession(store: store)
    }
  }

  func startBrowserSession() {
    MainActor.assumeIsolated {
      browserSession.start(initialWorkspaceId: current.id, workspaceName: current.name)
    }
  }

  func stopBrowserSession() {
    MainActor.assumeIsolated { browserSession.stop() }
  }

  /// `BrowserLayerView` と `OrbeWindow` のフォーカス監視を配線する。
  func wireBrowser() {
    window.onFirstResponderChange = { [weak self] responder in
      self?.firstResponderDidChange(responder)
    }
    browserView.onWindowCommand = { [weak self] command in
      self?.handleWindowCommand(command)
    }
    browserView.onRequestModeChange = { [weak self] mode, animated in
      self?.setBrowserMode(mode, animated: animated)
    }
  }

  /// `⌘B`。フォーカス位置を問わず純粋トグルで開閉する（閉 → 右シート、右シート・全面 → 閉）。
  func toggleBrowser() {
    setBrowserMode(browserMode.isOpen ? .closed : .sheet, animated: true)
  }

  /// Z=2 ブラウザ層のモード変更の単一入口（単独操作用）。
  /// `optionHold` を打ち切ってから `syncPeekState` で Z=1/Z=2 の透かしと露出端末の `done` 消費を同期する。
  func setBrowserMode(_ next: BrowserMode, animated: Bool) {
    guard next != browserMode else { return }
    let previous = browserMode
    applyBrowserMode(next, animated: animated)
    syncPeekState(animated: animated)
    if next.isOpen {
      browserWasFocused = true
      if model.overlay == .none {
        browserView.focusBrowser()
      }
    } else if previous.isOpen {
      browserWasFocused = false
      if model.overlay == .none {
        focusSelection()
      }
    }
    syncBrowserFocusVisual()
  }

  /// 下層へ明示的に移る命令（`select`・`toggleEditorFace`）の共通前処理。
  /// 焦点記憶を必ず下層へ譲り、全面ブラウザは閉じる。`closingSheet` が真なら右シートも閉じ、
  /// 偽なら右シートは URL 編集だけを外因終了して残す。
  /// 途中状態の誤消費を防ぐため `done` 消費と焦点復帰・非焦点見た目の更新は行わず、後続の `renderSelection` に委ねる。
  func yieldBrowserToUnderlay(animated: Bool, closingSheet: Bool = false) {
    browserWasFocused = false
    if browserMode == .full || (closingSheet && browserMode == .sheet) {
      applyBrowserMode(.closed, animated: animated)
    } else if browserMode == .sheet {
      browserView.endURLEditingExternally()
    }
  }

  private func applyBrowserMode(_ next: BrowserMode, animated: Bool) {
    browserMode = next
    optionHold.interrupt()
    browserView.endURLEditingExternally()
    browserView.setMode(next, animated: animated)
  }

  /// `OrbeWindow.makeFirstResponder` 成功後の同期通知。
  /// ここでは `makeFirstResponder` を絶対に呼ばない（再帰・フォーカス競合の防止）。
  func firstResponderDidChange(_ responder: NSResponder?) {
    if model.overlay == .none {
      if browserView.focusIsInside {
        browserWasFocused = true
      } else if let view = responder as? NSView, view.isDescendant(of: model.content) {
        browserWasFocused = false
      }
    }
    syncBrowserFocusVisual()
  }

  /// 窓の key 状態と実 first responder からブラウザ層の見た目（影・左層ベール・ツールバー減光）を同期する。
  func syncBrowserFocusVisual() {
    browserView.setFocused(window.isKeyWindow && browserView.focusIsInside)
  }
}
