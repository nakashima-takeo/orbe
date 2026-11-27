import AppKit

/// 上のバーの右下の置き場——ポップアップの器と札を並べる host を、バーより下の層に置く。ポップアップを開いたら、開く前の
/// フォーカスの場所を覚えてフォーカスの行き先を見張り、閉じたら、きっかけが求めれば覚えた場所へ戻す。閉じるきっかけは、
/// 右端のボタンの再クリック・外の押下・画面の切り替え・⌘E・cd・フォーカスが置き場の外へ移ったこと（ここで見る）と、載せる側の
/// 頼み（esc・中身の操作が通った）。
extension EditorPaneView {
  func wireDock() {
    popup.onOpen = { [weak self] in self?.popupDidOpen() }
    popup.onClose = { [weak self] dismissal in self?.popupDidClose(dismissal) }
    shell.actionButtonFrameDidChange = { [weak self] id, frame in
      self?.actionButtonFrames[id] = frame
    }
  }

  /// 置き場の根。根へ渡す持ち主は、ここで足す。
  func dockRoot() -> EditorDockRoot {
    EditorDockRoot(
      shell: shell, popup: popup, commitPopup: commitPopup, reviewPopup: reviewPopup,
      localization: localization,
      fontResolver: fontResolver,
      translucency: translucency ?? ChromeTranslucency(),
      framesDidChange: { [weak self] frames in self?.dockHost.itemFrames = frames })
  }

  /// フォーカスが置き場の host の配下（ポップアップと、その下に並ぶ物）にあるか。
  var focusIsInDock: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder.isDescendant(of: dockHost)
  }

  /// 置き場の host を置き（`layout()` から。影の余白の分だけ置き場の矩形より広い）、本体の上端の帯の高さを写す（札が帯を
  /// 覆わないように）。
  func layoutDock() {
    let margin = EditorDockRoot.margin
    dockHost.frame = dockRect.insetBy(dx: -margin, dy: -margin)
    let band = bodyBandHeight
    if shell.bodyBandHeight != band { shell.bodyBandHeight = band }
  }

  /// 窓の押下 `event` が、置き場に並んでいる物か、右端の主な操作のボタンの上か。
  func pressIsOnDock(_ event: NSEvent) -> Bool {
    if let view = window?.contentView?.hitTest(event.locationInWindow),
      view.isDescendant(of: dockHost)
    {
      return true
    }
    let point = convert(event.locationInWindow, from: nil)
    return actionButtonFrames.values.contains { $0.contains(point) }
  }

  /// 開いた。一覧の器が開いていれば閉じ、開く前のフォーカスの場所を覚え、一覧のためのフォーカスの預かりを終え、置き直して
  /// から、フォーカスの行き先の見張りを始める。
  private func popupDidOpen() {
    if itemList.isOpen { itemList.close(.otherOpened) }
    popupReturn = focusPlace
    endListFocusHold()
    needsLayout = true
    layoutSubtreeIfNeeded()
    popupFocusWatch = watchFocus(
      in: dockHost, onLeave: { [weak self] in self?.popup.close(.focusLeft) },
      onFall: { [weak self] in self?.popup.close(.itemGone) })
  }

  /// 閉じた。見張りをやめ、きっかけが求めれば、覚えた場所へフォーカスを戻す——中身の view はまだ外れていないので、
  /// フォーカスを持ったまま外れて窓へ落ちる前に、ここで移す。
  private func popupDidClose(_ dismissal: EditorDismissal) {
    popupFocusWatch = nil
    containerDidClose(dismissal)
    if dismissal.returnsFocus { returnFocus(to: popupReturn) }
    needsLayout = true
  }

  /// 窓の first responder の変化を、次のターン（落ち着いた先）で見る見張りを始める——`host` の配下なら何もせず、窓そのもの
  /// （フォーカスを持っていた view が外れた）なら `onFall`、それ以外なら `onLeave` を呼ぶ。返した見張りを捨てると止まる。
  /// 窓に付いていなければ nil。
  func watchFocus(
    in host: NSView, onLeave: @escaping () -> Void, onFall: @escaping () -> Void
  ) -> EditorFocusWatch? {
    guard let window else { return nil }
    return EditorFocusWatch(window: window, host: host, onLeave: onLeave, onFall: onFall)
  }
}

/// 窓の first responder の見張り（→ `EditorPaneView.watchFocus`）。変化はフォーカスの移動の途中に届くので、次のターンに、
/// 落ち着いた先で分ける。捨てると止まり、捨てる前に届いた変化も見ない。
@MainActor
final class EditorFocusWatch {
  private var observation: NSKeyValueObservation?

  init(
    window: NSWindow, host: NSView, onLeave: @escaping () -> Void, onFall: @escaping () -> Void
  ) {
    observation = window.observe(\.firstResponder) { [weak self, weak host] window, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard self != nil, let host else { return }
          let responder = window.firstResponder
          if responder === window {
            onFall()
          } else if (responder as? NSView)?.isDescendant(of: host) != true {
            onLeave()
          }
        }
      }
    }
  }
}
