import AppKit

/// 差分のファイルの見出し——本体が diff の間、本体の上端に置く帯。出すものは見出しの root が一覧の持ち主から導き、pane は
/// 本体の diff の値（どの diff か・新しい側の文書が未保存か）を写して、押されたときの操作を受ける。
extension EditorPaneView {
  /// 見出しに写す本体の diff の値（本体が diff でなければ nil）。
  var headerSubject: DiffFileHeaderRoot.Subject? {
    guard let diff else { return nil }
    return DiffFileHeaderRoot.Subject(
      key: diff.id, usesDocument: diff.document != nil, isDirty: diff.document?.isDirty == true)
  }

  /// 見出しの見え隠れと写しを本体に合わせる（写しが変わらなければ root を替えない）。
  func refreshHeader() {
    let subject = headerSubject
    headerHost.isHidden = subject == nil
    if headerHost.rootView.subject != subject { headerHost.rootView = headerRoot(subject) }
  }

  func headerRoot(_ subject: DiffFileHeaderRoot.Subject?) -> DiffFileHeaderRoot {
    DiffFileHeaderRoot(
      localization: localization, subject: subject, scm: scm,
      openFile: { [weak self] in self?.openHeaderFile() },
      toggleViewed: { [weak self] in self?.toggleHeaderViewed() })
  }

  /// 「ファイルを開く」——本体の diff のファイルを普通の文書として開き、Files の画面を選んで本文へ焦点を移す（左の列の行の
  /// 「ファイルを開く」と同じ口）。
  func openHeaderFile() {
    guard let diff else { return }
    open(diff.id.url, as: .pinned)
  }

  /// 本体の PR の diff のファイルの確認済みを付け外しする（diff が持つ PR ごとの状態へ書く）。
  func toggleHeaderViewed() {
    guard let diff, case .pullRequest(let state) = diff.id.kind else { return }
    let path = diff.id.path
    state.setViewed(!state.isViewed(path), paths: [path])
  }

  /// PR の画面のキー v: 本体の PR の diff のファイルの確認済みを付け外しする（見出しの「確認済みにする」と同じ口）。修飾の無い
  /// 字のキーは key equivalent として pane に届かず、first responder の keyDown へ直行する（読むだけの面は黙って捨てる）ので、
  /// ここで拾う。働くのは、見出しに確認済みの部品が出ていて、焦点が字を打つ場に無いとき——diff の面（主が読むだけの場）・
  /// pane 自身（一覧のために焦点を預かっている間を除く）・PR のパネルの列。焦点が列にあり、列で選んでいるファイルが本体のファイルと違えば、その diff を待たずに開いて
  /// から付け外しし、開けなければ音で断る。押し続けて届く繰り返しは、付け外しせずに捨てる。扱ったら true。
  func handleViewedKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard flags.isEmpty, event.charactersIgnoringModifiers == "v",
      group?.editor.screen == .pullRequest, let diff,
      headerSubject?.header(scm: scm).viewed != nil, let place = viewedKeyPlace(diff)
    else { return false }
    guard !event.isARepeat else { return true }
    if place == .list, !alignBodyWithListSelection() {
      NSSound.beep()
      return true
    }
    toggleHeaderViewed()
    return true
  }

  /// キー v を受ける焦点の場所。
  private enum ViewedKeyPlace {
    case body
    case list
  }

  /// 焦点がキー v を受ける場所にあるか（字を打つ場——入力の文脈を持つ view——は外す）。面自身の焦点は、一覧のために
  /// 預かっている間は左の列の焦点なので、受けない。
  private func viewedKeyPlace(_ diff: EditorDiff) -> ViewedKeyPlace? {
    guard let responder = window?.firstResponder as? NSView, responder.inputContext == nil
    else { return nil }
    if responder === self, !focusIsInSidebar { return .body }
    if diffSurfaces(diff).contains(where: { $0.responder === responder }) { return .body }
    if responder.isDescendant(of: pullRequestList) { return .list }
    return nil
  }

  /// PR のパネルの列で選んでいる行がファイルで、本体のファイルと違えば、その diff を待たずに開く。本体が列の選択に揃った
  /// （選んでいるのがファイルでなければ、そのまま）なら true。
  private func alignBodyWithListSelection() -> Bool {
    guard case .file(let path)? = pullRequest.selection, diff?.id.path != path else { return true }
    pullRequest.openSelection(.browse)
    return diff?.id.path == path
  }
}
