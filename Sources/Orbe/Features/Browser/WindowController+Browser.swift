import AppKit

/// ウィンドウ単一の内蔵ブラウザ層（Z=2）の配線・開閉・モード切替・フォーカス同期。
extension WindowController {
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
    browserView.onRatioChange = { [weak self] ratio in
      self?.browserSheetRatio = ratio
    }
  }

  /// `⌘B`。フォーカス位置を問わず純粋トグルで開閉する（閉 → 右シート、右シート・全面 → 閉）。
  func toggleBrowser() {
    setBrowserMode(browserMode.isOpen ? .closed : .sheet, animated: true)
  }

  /// Z=2 ブラウザ層のモード変更の単一入口。
  /// `optionHold` を打ち切ってから `syncPeekState` で Z=1/Z=2 を同期し、全面解除等で露出した端末の `done` を消費する。
  func setBrowserMode(_ next: BrowserMode, animated: Bool, restoreFocus: Bool = true) {
    guard next != browserMode else { return }
    let previous = browserMode
    browserMode = next
    optionHold.interrupt()
    browserView.endURLEditingExternally()
    browserView.setSheetRatio(browserSheetRatio)
    browserView.setMode(next, animated: animated)
    syncPeekState(animated: animated)
    if next.isOpen {
      browserWasFocused = true
      if restoreFocus, model.overlay == .none {
        browserView.focusBrowser()
      }
    } else if previous.isOpen {
      browserWasFocused = false
      if restoreFocus, model.overlay == .none {
        focusSelection()
      }
    }
    syncBrowserFocusVisual()
    consumeVisibleTabDone()
  }

  /// 下層へ明示的に移る命令（`select`・`showInEditor`・`toggleEditorFace`）の共通前処理。
  /// 焦点記憶を必ず下層へ譲り、全面ブラウザは閉じ、右シートは残して非焦点見た目へ更新する。
  func yieldBrowserToUnderlay(animated: Bool) {
    browserWasFocused = false
    if browserMode == .full {
      setBrowserMode(.closed, animated: animated, restoreFocus: false)
    } else if browserMode == .sheet {
      browserView.endURLEditingExternally()
      syncBrowserFocusVisual()
    }
  }

  /// `OrbeWindow.makeFirstResponder` 成功後の同期通知。
  /// ここでは `makeFirstResponder` を絶対に呼ばない（再帰・フォーカス競合の防止）。
  func firstResponderDidChange(_ responder: NSResponder?) {
    if model.overlay == .none, statusModel.editingIndex == nil {
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
