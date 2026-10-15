import Foundation
import OrbeEditorCore

/// 連（`TabGroup`）1 つが持つ、エディター面のタブの列（文書のタブと diff のタブ）と焦点のタブ。連のタブはどれも同じ
/// セッションを見る。文書は実体の URL ごとに 1 つで、テキスト面 1 つを開いてから閉じるまで対で持ち、その文書を使うタブ
/// （ファイルタブと、それを新しい側に使う作業ツリー diff）が持ち主になる——最後の持ち主が離れたら閉じる。切り替えは
/// 「どのタブの本体を見せるか」を変えるだけなので、undo・選択・スクロールは文書ごとに残る（同じ文書のファイルタブと作業
/// ツリー diff は、同じ面の位置・選択・undo を共有する）。変化は `onChange` 1 本で連へ上がる。
///
/// 列の中に仮のタブ（見るだけのタブ）を高々 1 つ持つ——文書と diff で枠は 1 つ。仮で開くと今の仮のタブをその位置で入れ替える
/// ので、見て回るだけなら列が伸びない。仮のタブの文書は常に未保存でない——未保存になった瞬間に普通のタブへ戻すので、入れ替えで
/// 中身を失わない。普通のタブは仮に戻らない。
@MainActor
final class EditorSession {
  /// 開き方。入口ごとにどちらかを必ず選ぶ（どの入口が仮かは `docs/spec/editor/shell.md` の「仮のタブ」が持つ）。
  enum OpenMode {
    /// 仮のタブとして開く。既に開いていれば焦点を移すだけ（普通のタブは普通のまま）。
    case preview
    /// 普通のタブとして開く。既に開いている仮のタブなら普通に変える。
    case pinned
  }

  private let surfaces: EditorSurfaces
  private(set) var tabs: [EditorTab] = []
  private(set) var activeID: EditorTab.Key?
  /// 仮のタブ（列の中の 1 つか nil）。
  private(set) var previewID: EditorTab.Key?
  /// 文書ごとの根のサービスとの結線。文書と同寿命（閉じれば捨てる）。
  private var links: [ObjectIdentifier: DocumentLink] = [:]
  /// 列・焦点・仮のタブ・未保存の有無・「ディスクが変わった」の有無が変わった。
  var onChange: (() -> Void)?
  /// 本体のテキスト面が first responder になった／やめた。
  var onFocusChange: (() -> Void)?

  init(surfaces: EditorSurfaces) {
    self.surfaces = surfaces
  }

  /// 焦点のタブ。
  var activeTab: EditorTab? { activeID.flatMap(tab) }

  /// 焦点のタブが文書のタブなら、その文書。
  var activeDocument: EditorDocument? {
    if case .document(let document)? = activeTab { return document }
    return nil
  }

  func tab(_ id: EditorTab.Key) -> EditorTab? { tabs.first { $0.id == id } }

  /// 開いている文書（タブの列の順に、それを使う最初のタブの位置で 1 つずつ）。
  var documents: [EditorDocument] {
    var seen = Set<ObjectIdentifier>()
    return tabs.compactMap(\.document).filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  /// 閉じれば失われる文書（未保存の列）。
  func documentsToDiscard() -> [EditorDocument] { documents.filter(\.isDirty) }

  /// 永続から戻す。順に開き（読めないパスは黙って落とす）、`preview` のパスの文書を仮にし、`active` が残っていればそれを、
  /// 無ければ先頭を焦点にする。既に居るものは壊さない——materialize より先に制御 API の `open_file` が文書を開いて
  /// いれば、その文書の開き方と焦点を保つ。通知は 1 本にまとめる。
  func restore(paths: [String], active: String, preview: String?) {
    let previewURL = preview.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    var restored: [EditorTab.Key] = []
    for path in paths {
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      guard tab(.document(url)) == nil, let document = try? document(for: url) else { continue }
      tabs.append(.document(document))
      restored.append(.document(url))
      if previewID == nil, url == previewURL { previewID = .document(url) }
    }
    guard !restored.isEmpty else { return }
    let activeURL = URL(fileURLWithPath: active).resolvingSymlinksInPath()
    activeID =
      activeID ?? restored.first { $0 == .document(activeURL) } ?? tabs.first?.id
    onChange?()
  }

  /// ファイルを `mode` のファイルタブで開いて焦点にする。既に開いていれば焦点を移すだけ（`.pinned` なら仮のタブを普通に
  /// 変える）。仮で新しく開けば、今の仮のタブをその位置で入れ替える（閉じる＋開くを 1 本の通知で）。文書が diff のために
  /// 既に開いていればそれを使う。読めない・UTF-8 でなければ文書のエラー、テキスト面を作れなければ
  /// `EditorSurfaceError.noMetalDevice` で失敗し、列・仮のタブは変わらない。文書の識別は symlink を解いた実体のパス——
  /// 保存は一時ファイルの rename なので、リンクのパスへ書くとリンク自体が通常ファイルに置き換わり実体へ届かない。同じ実体を
  /// 別の綴りで開いても文書が割れない。
  @discardableResult
  func open(_ url: URL, as mode: OpenMode) throws -> EditorDocument {
    let url = url.resolvingSymlinksInPath()
    if case .document(let existing)? = tab(.document(url)) {
      focus(.document(url), as: mode)
      return existing
    }
    let document = try document(for: url)
    place(.document(document), as: mode)
    return document
  }

  /// diff `id` を `mode` の diff タブで開いて焦点にする（既に開いていれば焦点を移すだけ）。作業ツリー diff の新しい側は
  /// その実体の文書——開いていればそれを使い、無ければ開いて持つ（タブには出ない）。どの文書を使うかは diff が作業ツリーの
  /// 姿から決め直す。テキスト面を作れなければ `EditorSurfaceError.noMetalDevice` で失敗する。
  @discardableResult
  func openDiff(_ id: EditorDiff.Key, as mode: OpenMode) throws -> EditorDiff {
    if case .diff(let existing)? = tab(.diff(id)) {
      focus(.diff(id), as: mode)
      return existing
    }
    let diff = try EditorDiff(id: id, documents: diffDocuments, surfaces: surfaces)
    place(.diff(diff), as: mode)
    return diff
  }

  /// diff が新しい側の文書を引く口と手放す口（このセッション）。
  private var diffDocuments: EditorDiff.Documents {
    EditorDiff.Documents(
      open: { [unowned self] url in try document(for: url) },
      release: { [weak self] document in self?.documentLeft(document) })
  }

  /// diff が使わなくなった文書——ほかに使うタブが無ければ閉じる。
  private func documentLeft(_ document: EditorDocument) {
    if !tabs.contains(where: { $0.document === document }) {
      links[ObjectIdentifier(document)] = nil
    }
    settlePreview()
    onChange?()
  }

  /// 開いているタブ `id` へ焦点を移す（`.pinned` なら仮のタブを普通に変える）。
  private func focus(_ id: EditorTab.Key, as mode: OpenMode) {
    let pins = mode == .pinned && previewID == id
    guard pins || activeID != id else { return }
    if pins { previewID = nil }
    activeID = id
    onChange?()
  }

  /// 新しいタブを列へ置いて焦点にする（仮なら今の仮のタブをその位置で入れ替える）。
  private func place(_ tab: EditorTab, as mode: OpenMode) {
    if mode == .preview, let old = previewID, let index = tabs.firstIndex(where: { $0.id == old }) {
      let replaced = tabs[index]
      tabs[index] = tab
      release(replaced)
    } else {
      tabs.append(tab)
    }
    if mode == .preview { previewID = tab.id }
    activeID = tab.id
    settlePreview()
    onChange?()
  }

  /// 実体 `url` の文書（開いていればそれ、無ければ読んで面を作って結線する。列に入るのは、使うタブを置いたとき）。
  private func document(for url: URL) throws -> EditorDocument {
    if let existing = documents.first(where: { $0.url == url }) { return existing }
    let contents = try EditorDocument.read(url)
    guard let surface = surfaces.make() else { throw EditorSurfaceError.noMetalDevice }
    let document = EditorDocument(
      url: url, contents: contents, surface: surface, registry: surfaces.registry)
    own(document, link: DocumentLink(document: document))
    return document
  }

  /// 文書の通知をこのセッションへ結び、結線を持つ。
  private func own(_ document: EditorDocument, link: DocumentLink?) {
    document.onDirtyChange = { [weak self] _ in
      guard let self else { return }
      settlePreview()
      onChange?()
    }
    document.onDiskChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] _ in self?.onFocusChange?() }
    links[ObjectIdentifier(document)] = link
  }

  /// 別のセッションのタブを列の末尾へ引き取る（cd で連が畳まれたとき）。文書（diff だけが使う文書を含む）は実体ごとに
  /// 勝ち負けを決める——自分に無ければ結線ごと移す。あれば、`other` の文書だけが未保存のときに限り `other` の文書が
  /// 勝ち、それ以外は自分の文書が勝つ（負けた側は未保存でも捨てる）。タブは `other` の列の順に見て、同じタブが自分に
  /// あれば捨て、無ければ末尾へ足す。仮のタブは自分に仮が無いときだけ仮のまま移り、あれば普通のタブになる。足した後、
  /// 列のすべての文書のタブと diff の新しい側を勝った文書に揃える。焦点は自分のものを保ち、自分にタブが無かったときだけ
  /// `other` の焦点にする。`other` は通知なしに空になり、自分の変化は 1 本の通知で上げる。本体を見せていた pane は、
  /// 呼ぶ前に手放しておく。
  func adopt(from other: EditorSession) {
    guard !other.tabs.isEmpty else { return }
    let wasEmpty = tabs.isEmpty
    let winners = settleDocuments(from: other)
    for tab in other.tabs {
      guard self.tab(tab.id) == nil else {
        if case .diff(let diff) = tab { diff.dismiss() }
        continue
      }
      if case .diff(let diff) = tab { diff.rebind(diffDocuments) }
      tabs.append(tab)
      if tab.id == other.previewID, previewID == nil { previewID = tab.id }
    }
    replaceLosers(with: winners)
    if wasEmpty {
      activeID = other.activeID.flatMap { tab($0)?.id } ?? tabs.first?.id
    }
    let used = Set(documents.map(ObjectIdentifier.init))
    links = links.filter { used.contains($0.key) }
    other.tabs = []
    other.links = [:]
    other.activeID = nil
    other.previewID = nil
    settlePreview()
    for case .diff(let diff) in tabs { diff.settle() }
    onChange?()
  }

  /// `other` の文書の勝ち負けを実体ごとに決め、移る文書（自分に無いもの・勝ったもの）を結線ごと引き取る。戻り値は両方に
  /// あった実体の勝者。
  private func settleDocuments(from other: EditorSession) -> [URL: EditorDocument] {
    var winners: [URL: EditorDocument] = [:]
    for document in other.documents {
      let link = other.links[ObjectIdentifier(document)]
      guard let mine = documents.first(where: { $0.url == document.url }) else {
        own(document, link: link)
        continue
      }
      let theirs = document.isDirty && !mine.isDirty
      winners[document.url] = theirs ? document : mine
      if theirs { own(document, link: link) }
    }
    return winners
  }

  /// 列の文書のタブと diff の新しい側を、その実体の勝者に揃える（文書のタブは同じ位置で置き換える）。
  private func replaceLosers(with winners: [URL: EditorDocument]) {
    for (index, tab) in tabs.enumerated() {
      guard let document = tab.document, let winner = winners[document.url], winner !== document
      else { continue }
      switch tab {
      case .document: tabs[index] = .document(winner)
      case .diff(let diff): diff.replaceDocument(with: winner)
      }
    }
  }

  /// 仮のタブの文書が未保存なら普通のタブにする（入れ替えで中身を失わない）。
  private func settlePreview() {
    guard let previewID, tab(previewID)?.document?.isDirty == true else { return }
    self.previewID = nil
  }

  /// テキスト面を描く用意を裏で始める（エディター面が初めて見えたとき。何度呼んでもよい）。
  func prepareSurfaces() {
    surfaces.prepare()
  }

  func activate(_ id: EditorTab.Key) {
    guard activeID != id, tab(id) != nil else { return }
    activeID = id
    onChange?()
  }

  /// 仮のタブを普通のタブにする（仮でなければ何もしない）。
  func pin(_ id: EditorTab.Key) {
    guard previewID == id else { return }
    previewID = nil
    onChange?()
  }

  /// 焦点の文書のタブの文書を保存する。force でなければ、ディスクが変わっていれば失敗する（→ `EditorDocument.save`）。
  /// 仮のタブは保存しても仮のまま。diff のタブには保存が無い。
  func saveActive(force: Bool = false) throws {
    try activeDocument?.save(force: force)
  }

  /// タブ `id` を閉じたときに閉じる文書（その文書を使う最後のタブなら、その文書。ほかのタブが使っていれば nil）。未保存の
  /// 確認は、これが未保存のときだけ出す。
  func documentClosed(byClosing id: EditorTab.Key) -> EditorDocument? {
    guard let document = tab(id)?.document else { return nil }
    return tabs.contains { $0.id != id && $0.document === document } ? nil : document
  }

  /// タブを閉じる。未保存でも黙って捨てる（その文書を使う最後のタブなら文書と面も閉じる）。焦点だったタブを閉じれば隣の
  /// タブへ。
  func close(_ id: EditorTab.Key) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let closed = tabs.remove(at: index)
    release(closed)
    if previewID == id { previewID = nil }
    if activeID == id {
      activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }
    settlePreview()
    onChange?()
  }

  /// 列から外したタブの文書を、もう使うタブが無ければ閉じる。
  private func release(_ closed: EditorTab) {
    if case .diff(let diff) = closed { diff.dismiss() }
    guard let document = closed.document, !tabs.contains(where: { $0.document === document })
    else { return }
    links[ObjectIdentifier(document)] = nil
  }
}
