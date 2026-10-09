import AppKit
import OrbeEditorCore

/// diff の本体——インラインなら新しい側の面 1 枚、並列なら左右 2 面と境の線（1px）、表示できないなら理由の一文（空状態と
/// 同じ器）。見え方の付け外しは diff の `present` / `dismiss` で、本体を置き換える 1 か所（`show`）からだけ呼ぶ。
extension EditorPaneView {
  /// diff を本体に載せる——今の見せ方で見せ、面を置き、知らせを結ぶ。
  func showDiff(_ diff: EditorDiff) {
    diffFocusesLeft = false
    diff.onPresentationChange = { [weak self, weak diff] in
      guard let self, let diff, self.diff === diff else { return }
      installDiffSurfaces(diff)
      refreshNotice()
      needsLayout = true
    }
    diff.present(diffModes.mode)
    installDiffSurfaces(diff)
  }

  /// diff を本体から外す——面を外し、知らせを解き、見せるのをやめる（文書の面はコードの見え方に戻る）。
  func hideDiff(_ diff: EditorDiff) {
    diff.onPresentationChange = nil
    observeDiff(diff, false)
    for view in diffViews { view.removeFromSuperview() }
    diffViews = []
    diffDivider.removeFromSuperview()
    diff.dismiss()
  }

  /// 見せている diff の面（左から）。
  func diffSurfaces(_ diff: EditorDiff) -> [any TextSurface] {
    guard let right = diff.newSurface else { return [] }
    guard let left = diff.oldSurface, diff.presented == .side else { return [right] }
    return [left, right]
  }

  /// diff の面を本体に置き直す（並列の古い側の面ができた・中身が見せられるようになった・表示できなくなった）。本体に
  /// 置いている面の view を覚えておき、今見せる面に無いものを外す——表示できなくなった diff は面を出さないので、理由の
  /// 一文を面が覆わない。
  func installDiffSurfaces(_ diff: EditorDiff) {
    observeDiff(diff, true)
    let surfaces = diffSurfaces(diff)
    let views = surfaces.map(\.view)
    let hadFocus = focusIsInside && !focusIsInSidebar
    for view in diffViews where !views.contains(where: { $0 === view }) {
      view.removeFromSuperview()
    }
    for surface in surfaces where surface.view.superview !== self { install(surface) }
    diffViews = views
    if surfaces.count == 2 {
      if diffDivider.superview !== self {
        addSubview(diffDivider, positioned: .below, relativeTo: sidebarHandle)
      }
    } else {
      diffDivider.removeFromSuperview()
    }
    paintDiffDivider()
    let responder = window?.firstResponder
    if hadFocus || responder === self, responder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
  }

  /// 境の線の色を今の外観で塗る（見本 hairline(.07)）。
  func paintDiffDivider() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      diffDivider.layer?.backgroundColor =
        EditorStyle.hairline(Theme.Opacity.editorDiffDivider).cgColor
    }
  }

  /// diff の面の矩形（並列なら左右に 1px の境を挟んで等分）。
  func layoutDiff(_ diff: EditorDiff) {
    let rect = bodyRect
    let surfaces = diffSurfaces(diff)
    guard surfaces.count == 2 else {
      surfaces.first?.view.frame = rect
      return
    }
    let line = Theme.Stroke.hairline
    let left = ((rect.width - line) / 2).rounded(.down)
    surfaces[0].view.frame = NSRect(x: rect.minX, y: rect.minY, width: left, height: rect.height)
    diffDivider.frame = NSRect(x: rect.minX + left, y: rect.minY, width: line, height: rect.height)
    surfaces[1].view.frame = NSRect(
      x: rect.minX + left + line, y: rect.minY, width: rect.width - left - line,
      height: rect.height)
  }

  /// diff の知らせを結ぶ——新しい側の文書の見えている範囲と本文の変化（文書の閉包 1 本を通して配る）と、面の焦点。
  /// 新しい側の文書は作業ツリーの姿で替わるので、前に結んだ文書の知らせを解いてから今の文書に結ぶ。
  private func observeDiff(_ diff: EditorDiff, _ on: Bool) {
    if let previous = diffDocument, previous !== diff.document || !on {
      previous.onViewportChange = nil
      previous.onTextChange = nil
    }
    diffDocument = on ? diff.document : nil
    if on, let document = diff.document {
      document.onViewportChange = { [weak diff] in diff?.viewportDidChange() }
      document.onTextChange = { [weak diff] _ in diff?.documentTextDidChange() }
    }
    diff.onFocusChange = on ? { [weak self] _ in self?.focusDidChange() } : nil
  }

  /// 本体に文字だけを出す器（空状態・表示できない diff の一文・読み込み中の diff）の見え隠れと中身。
  func refreshNotice() {
    switch body {
    case .document: emptyHost.isHidden = true
    case .diff(let diff): emptyHost.isHidden = diff.content == .ready
    case .empty: emptyHost.isHidden = false
    }
    let content = faceContent
    if emptyHost.rootView.content != content {
      emptyHost.rootView = EditorFaceRoot(localization: localization, content: content)
    }
  }

  /// 器に出すもの。
  var faceContent: EditorFaceRoot.Content {
    guard case .diff(let diff) = body else { return .empty }
    switch diff.content {
    case .ready, .loading: return .blank
    case .unavailable(.notText): return .notice(.editorDiffNotText)
    case .unavailable(.symlink): return .notice(.editorDiffSymlink)
    case .unavailable(.conflicted): return .notice(.editorDiffConflicted)
    case .unavailable(.failed): return .notice(.editorDiffFailed)
    }
  }

  /// 見せ方の選択を観測して、見せている diff を見せ直す（タブ行の右端の切り替えは写しにも写す）。
  func observeDiffModes() {
    withObservationTracking {
      _ = diffModes.mode
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if let diff {
          let hadFocus = focusIsInside && !focusIsInSidebar
          diff.present(diffModes.mode)
          installDiffSurfaces(diff)
          needsLayout = true
          if hadFocus, window?.firstResponder !== focusTarget {
            window?.makeFirstResponder(focusTarget)
          }
        }
        shell.diffMode = diffModes.mode
        observeDiffModes()
      }
    }
  }
}
