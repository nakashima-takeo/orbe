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
}
