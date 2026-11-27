import AppKit
import OrbeEditorCore

/// 上のバーの今の項目と、Files の一覧の中身。今の項目の写しと一覧の行は、同じ材料（開いている文書・仮の文書か・未保存・
/// ディスクが変わった・状態の字）から、ここで作る——ボタンと行で印を別々に導かない。
extension EditorPaneView {
  /// 今の項目を写し直す（値が変わらなければ書かない）。器が開いていれば、器に載せる側の中身を引き直させる。今の項目が
  /// 無くなったか種類が替わったら、器を閉じる。セッションが変わったとき・根が替わったとき（親のパスは根からの相対）・左の列の
  /// 開閉が変わったとき・一覧の持ち主（ソース管理の 2 区分・PR ごとの状態）が変わったときに呼ぶ。
  func refreshCurrentItem() {
    let next = currentItemValue
    if shell.currentItem != next { shell.currentItem = next }
    guard itemList.isOpen else { return }
    guard let owner = next.map(listOwner), itemList.owner === owner else {
      return itemList.close(.itemGone)
    }
    itemList.contentDidChange()
  }

  /// 今の項目の種類の一覧を載せる側。
  private func listOwner(_ item: EditorShellModel.CurrentItem) -> EditorItemListOwner {
    switch item {
    case .file: openFilesList
    case .diff: changedFilesList
    }
  }

  /// 今の項目——画面が Files で、今の文書があるとき、そのファイル。画面が Changes か PR で、左の列を閉じていて、本体が
  /// diff のとき、その diff。
  private var currentItemValue: EditorShellModel.CurrentItem? {
    guard let session = group?.editor else { return nil }
    guard session.screen == .files else {
      guard !sidebar.isOpen, let subject = headerSubject else { return nil }
      return .diff(subject)
    }
    guard let document = session.activeDocument else { return nil }
    let isPreview = session.previewURL == document.url
    let parent = directory(of: document.url)
    return .file(
      EditorShellModel.CurrentFile(
        chip: FileChip.resolve(document.url),
        directory: parent.isEmpty ? "" : parent + "/",
        name: document.url.lastPathComponent, isPreview: isPreview,
        mark: EditorItemListRow.Mark(document),
        showsKeepOpenKey: isPreview && showsSearchPanel && projectSearch.focusedArea == .results))
  }

  /// 検索結果の列のフォーカスの出入りを観測して、今の項目（キーの札 ↵ を出すか）を写し直す。
  func observeSearchFocus() {
    withObservationTracking {
      _ = projectSearch.focusedArea
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        self?.refreshCurrentItem()
        self?.observeSearchFocus()
      }
    }
  }

  /// ツリーの開いている印の写しを作り直す（値が変わったときだけ書く）。開いている文書（仮の文書を含む）の、根からの相対パス
  /// → 閉じられる行の印。根の外の文書は入れない。セッションが変わったとき・根が替わったときに呼ぶ。
  func refreshOpenMarks() {
    var marks: [String: EditorItemListRow.Mark] = [:]
    for document in group?.editor.documents ?? [] {
      if let path = tree.relativePath(of: document.url) { marks[path] = .closable(document) }
    }
    tree.setOpenMarks(marks)
  }

  /// 今の仮の文書を普通の文書にする（上のバーの「開いたままにする」。フォーカスは動かさない）。
  func keepCurrentOpen() {
    guard let session = group?.editor, let url = session.activeURL else { return }
    session.pin(url)
  }

  /// 今の項目のボタンを押す（⌘P も同じ）。開いていれば閉じ、閉じていれば今の項目の種類の一覧で開く。今の項目が無ければ
  /// 何もしない。
  func toggleItemList() {
    if itemList.isOpen { return itemList.close(.toggle) }
    guard let item = shell.currentItem else { return }
    itemList.open(listOwner(item))
  }

  // MARK: - Files の一覧の中身

  /// 一覧: 見出しの行（「開いているファイル N」と ⌘P）と、開いている文書の行（最近使った順）。1 行目の文書に「現在」の
  /// 札。開いたときに選ぶ行は 2 番目の文書（1 つだけなら 1 番目）。
  func openFilesContent() -> EditorItemListContent {
    let language = localization.language
    let documents = group?.editor.documents ?? []
    let files = documents.enumerated().map { index, document in
      fileRow(document, isCurrent: index == 0, closable: true)
    }
    let rows = OpenFilesRows(
      heading: .heading(
        title: L10n.string(.editorOpenFilesTitle, language), count: documents.count, key: "⌘P"),
      files: files, urls: documents.map(\.url))
    return EditorItemListContent(
      rows: rows, initialSelection: documents.dropFirst().first?.url ?? documents.first?.url,
      hints: [
        hint(.glyph(EditorGlyphs.returnKey), .editorItemListSwitch),
        hint(.glyph(EditorGlyphs.arrowRight), .editorItemListDetail),
        hint(.text("esc"), .editorItemListClose),
      ])
  }

  /// 文書 `url` の詳細: 先頭にその文書のファイルの行（選べない）、続けて「開いたままにする」（仮の文書だけ）と「ファイルを
  /// 閉じる」。開いたときに選ぶ行は最初の操作の行。文書が列に無ければ nil。
  func openFileDetail(_ url: URL) -> EditorItemListContent? {
    guard let session = group?.editor, let document = session.document(at: url) else { return nil }
    let language = localization.language
    var actions: [(id: OpenFileAction, title: String)] = []
    if session.previewURL == url {
      actions.append((.keepOpen(url), L10n.string(.editorOpenFilesKeepOpen, language)))
    }
    actions.append((.close(url), L10n.string(.editorOpenFilesCloseFile, language)))
    return EditorItemListContent(
      rows: OpenFileDetailRows(
        file: fileRow(document, isCurrent: session.activeDocument === document, closable: false),
        actions: actions),
      initialSelection: actions.first?.id,
      hints: [
        hint(.glyph(EditorGlyphs.returnKey), .editorItemListRun),
        hint(.glyph(EditorGlyphs.arrowLeft), .editorItemListBack),
        hint(.text("esc"), .editorItemListClose),
      ])
  }

  private func hint(_ key: EditorKeyCap.Content, _ label: L10nKey) -> EditorItemListHint {
    EditorItemListHint(key: key, label: L10n.string(label, localization.language))
  }

  /// 文書の行の値。`closable` なら右の印は × か丸（詳細の先頭の行は印を出さない）。
  private func fileRow(
    _ document: EditorDocument, isCurrent: Bool, closable: Bool
  ) -> EditorItemListRow.File {
    let language = localization.language
    let isPreview = group?.editor.previewURL == document.url
    var tags: [String] = []
    if isCurrent { tags.append(L10n.string(.editorOpenFilesCurrent, language)) }
    if isPreview { tags.append(L10n.string(.editorOpenFilesPreview, language)) }
    let state = EditorItemListRow.Mark(document)
    return EditorItemListRow.File(
      chip: FileChip.resolve(document.url), name: document.url.lastPathComponent,
      isItalic: isPreview, directory: directory(of: document.url), tags: tags,
      mark: closable ? .closable(document) : .none,
      badge: group?.editor.badge(of: document),
      closeLabel: L10n.string(.editorItemListClose, language),
      markLabel: markLabel(state))
  }

  private func markLabel(_ mark: EditorItemListRow.Mark) -> String? {
    switch mark {
    case .unsaved: L10n.string(.editorItemUnsaved, localization.language)
    case .diskChanged: L10n.string(.editorItemDiskChanged, localization.language)
    case .none, .close: nil
    }
  }

  /// 実体 `url` の親のディレクトリ——根の下なら根からの相対（根の直下は空）、根の外なら `~` で縮めた絶対。
  private func directory(of url: URL) -> String {
    let root = URL(fileURLWithPath: tree.root).resolvingSymlinksInPath().path
    let parent = url.deletingLastPathComponent().path
    if parent == root { return "" }
    if parent.hasPrefix(root + "/") { return String(parent.dropFirst(root.count + 1)) }
    return (parent as NSString).abbreviatingWithTildeInPath
  }
}
