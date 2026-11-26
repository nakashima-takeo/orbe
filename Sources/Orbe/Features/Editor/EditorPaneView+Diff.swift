import AppKit
import OrbeEditorCore

/// diff の本体——インラインなら新しい側の面 1 枚、並列なら左右 2 面と境の線（1px）、表示できないなら理由の一文（空状態と
/// 同じ器）。見え方の付け外しは diff の `present` / `dismiss`。見せ方は本体の幅で決まる。
extension EditorPaneView {
  /// 本体の今の幅での見せ方。
  var fittingDiffMode: EditorDiff.Mode { EditorDiff.Mode(bodyWidth: bodyRect.width) }

  /// diff を本体に載せる——本体の幅で決まる見せ方で見せ、面を置き、知らせを結ぶ。
  func showDiff(_ diff: EditorDiff) {
    diffFocusesLeft = false
    diff.onPresentationChange = { [weak self, weak diff] in
      guard let self, let diff, self.diff === diff else { return }
      installDiffSurfaces(diff)
      refreshNotice()
      refreshHeader()
      needsLayout = true
    }
    diff.present(fittingDiffMode)
    installDiffSurfaces(diff)
  }

  /// 見せている diff の見せ方を本体の幅に合わせる（配置の最初に呼ぶ）。面が見えていない間は見せ直さず、見えたときの配置で
  /// 合わせる。見せ直したら、主の入力欄が居る面を焦点の行き先にし（並列でなくなれば右へ戻す）、面の view を入れ替える——
  /// 焦点が本体にあれば、入れ替えがその行き先へ移す。
  func fitDiffMode() {
    let mode = fittingDiffMode
    guard let diff, isFaceVisible, let presented = diff.presented, presented != mode else { return }
    diff.present(mode)
    let fieldOnLeft = diff.primaryFieldSurface.map { $0 === diff.oldSurface } == true
    diffFocusesLeft = mode == .side && fieldOnLeft
    installDiffSurfaces(diff)
  }

  /// diff を本体から外す——面を外し、知らせを解き、見せるのをやめる（文書の面はコードの見え方に戻る）。
  func hideDiff(_ diff: EditorDiff) {
    diff.onPresentationChange = nil
    diff.comments?.endReveal()
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
    bindEditedDocument()
    let surfaces = diffSurfaces(diff)
    let views = surfaces.map(\.view)
    let hadFocus = focusIsInBody
    for view in diffViews where !views.contains(where: { $0 === view }) {
      view.removeFromSuperview()
    }
    for surface in surfaces where surface.view.superview !== belowBar { install(surface) }
    diffViews = views
    if surfaces.count == 2 {
      if diffDivider.superview !== belowBar {
        belowBar.addSubview(diffDivider, positioned: .below, relativeTo: headerHost)
      }
    } else {
      diffDivider.removeFromSuperview()
    }
    paintDiffDivider()
    if hadFocus, window?.firstResponder !== focusTarget {
      window?.makeFirstResponder(focusTarget)
    }
  }

  /// 境の線の色を今の外観で塗る（hairline .07）。
  func paintDiffDivider() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      diffDivider.layer?.backgroundColor =
        EditorStyle.hairline(Theme.Opacity.editorDiffDivider).cgColor
    }
  }

  /// diff の面の矩形——見出しの下（並列なら左右に 1px の境を挟んで等分）。
  func layoutDiff(_ diff: EditorDiff) {
    let rect = belowHeaderRect
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

  /// diff の面の焦点の知らせを結ぶ（新しい側の文書の知らせは、本体で編集する文書として `bindEditedDocument` が結ぶ）。
  private func observeDiff(_ diff: EditorDiff, _ on: Bool) {
    diff.onFocusChange = on ? { [weak self] _ in self?.focusDidChange() } : nil
  }

  /// 本体に文字だけを出す器（空・使えないときの表示・表示できない diff の一文・読み込み中の diff）の見え隠れと中身。
  func refreshNotice() {
    switch body {
    case .document: faceHost.isHidden = true
    case .diff(let diff): faceHost.isHidden = diff.content == .ready
    case .empty: faceHost.isHidden = false
    }
    let content = faceContent
    if faceHost.rootView.content != content { faceHost.rootView = faceRoot(content) }
  }

  /// 器の root。空・使えないときの表示は今の一覧の状態を読み、ボタンの外を押せば面が焦点を取る。
  func faceRoot(_ content: EditorFaceRoot.Content) -> EditorFaceRoot {
    EditorFaceRoot(
      localization: localization, content: content, scm: scm, pullRequest: pullRequest
    ) { [weak self] in self?.focusEditor() }
  }

  /// 器に出すもの。本体が空なら、その画面の空・使えないときの表示。
  var faceContent: EditorFaceRoot.Content {
    guard case .diff(let diff) = body else { return .empty(group?.editor.screen ?? .files) }
    switch diff.content {
    case .ready, .loading: return .blank
    case .unavailable(.notText): return .notice(.editorDiffNotText)
    case .unavailable(.symlink): return .notice(.editorDiffSymlink)
    case .unavailable(.directory): return .notice(.editorDiffDirectory)
    case .unavailable(.unreadable): return .notice(.editorDiffUnreadable)
    case .unavailable(.conflicted): return .notice(.editorDiffConflicted)
    case .unavailable(.failed): return .notice(.editorDiffFailed)
    case .unavailable(.nowhere):
      switch diff.id.kind {
      case .workingTree: return .notice(.editorDiffNowhereInWorkingTree)
      case .staged: return .notice(.editorDiffNowhereStaged)
      case .pullRequest: return .notice(.editorDiffNowherePullRequest)
      }
    case .unavailable(.pullRequestCommitsMissing):
      return .notice(.editorDiffPullRequestCommitsMissing)
    case .unavailable(.pullRequestUnrelated):
      return .notice(.editorDiffPullRequestUnrelated)
    }
  }

  // MARK: - 本体の diff を整合させる

  /// diff `key` を、その種類の画面の diff として開き、左の列でその行を選択表示する（行がまだ一覧に無ければ、行ができたとき
  /// に）。画面は選ばない。テキスト面を作れなければ `EditorSurfaceError.noMetalDevice` で失敗する。
  func openDiff(_ key: EditorDiff.Key) throws {
    guard let group else { return }
    try group.editor.openDiff(key)
    revealRow(of: key)
  }

  /// diff `key` の行を左の列の一覧で選ぶ（畳んだ区分・フォルダは開く）。一覧にまだ無ければ、行ができたときに選ぶ。
  private func revealRow(of key: EditorDiff.Key) {
    let revealed =
      switch key.kind {
      case .workingTree, .staged: scm.reveal(scm.rowID(of: key))
      case .pullRequest(let state):
        pullRequest.state === state && pullRequest.reveal(file: key.path)
      }
    diffAwaitingRow = revealed ? nil : key
  }

  /// 一覧の行が揃ったら済ませる用事（本体の diff・一覧のための焦点の預かり）を、画面・面の可視性・一覧の行・worktree の
  /// 今の PR に合わせる 1 か所。きっかけは、セッションの変化（画面が替わった・diff が閉じた）・面の可視性の変化・一覧の行の
  /// 組み直し・一覧の状態の変化・worktree の今の PR の答えの変化。
  /// - 焦点を預かっていれば、一覧の状態に合わせて進める（→ `advanceListFocusHold`）。
  /// - PR の diff の PR が、worktree の今の PR（答えが出ているとき）と違えば閉じる。
  /// - 開いた diff の行を待っていれば、行ができたときに選ぶ。
  /// - 面が見えていて、今の画面（Changes・PR）に diff が無く、一覧にファイルの行があれば、選んでいる行（ファイルの行でなければ
  ///   先頭のファイルの行）を開く。画面は選ばず、焦点も動かさない。開けなければ何もしない（次のきっかけまで試さない）。
  func reconcileWithLists() {
    advanceListFocusHold()
    guard let group else { return }
    let session = group.editor
    if case .pullRequest(let state)? = session.pullRequestDiff?.id.kind, hasPullRequestAnswer,
      pullRequest.state !== state
    {
      session.closeDiff(on: .pullRequest)
      return
    }
    if let key = diffAwaitingRow {
      if session.diff(on: key.kind.screen)?.id == key {
        revealRow(of: key)
      } else {
        diffAwaitingRow = nil
      }
    }
    guard isFaceVisible, session.diff(on: session.screen) == nil else { return }
    let key: EditorDiff.Key?
    switch session.screen {
    case .changes: key = scm.rowToOpen.flatMap(scm.diffKey(of:))
    case .pullRequest: key = pullRequest.fileToOpen.flatMap(pullRequest.diffKey(of:))
    case .files: key = nil
    }
    guard let key else { return }
    try? openDiff(key)
  }

  /// worktree の今の PR の答えが出ている（読んでいる最中でない）。
  private var hasPullRequestAnswer: Bool {
    if case .reading = pullRequest.pullRequest.answer { return false }
    return true
  }
}
