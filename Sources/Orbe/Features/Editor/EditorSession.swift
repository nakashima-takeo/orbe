import Foundation
import OrbeEditorCore

/// 連（`TabGroup`）1 つが持つ、エディターの中身——選んだ画面、Files の開いている文書の列（今の文書・仮の文書）、Changes の
/// diff（0〜1）、PR の diff（0〜1）。連のタブはどれも同じセッションを見る。本体は画面から導く（→ `body`）。
///
/// 文書は実体の URL ごとに 1 つで、テキスト面 1 つを開いてから閉じるまで対で持つ。持ち主は開いている文書の列と、それを新しい
/// 側に使う Changes の diff（作業ツリー diff）——どちらも手放したら閉じる。同じ文書の本体と diff の新しい側は、同じ面の位置・
/// 選択・undo を共有する。未保存になった文書は列に入る——diff は入れ替わり、閉じる操作を持たないので、人が打った内容は diff の
/// 外（開いている文書の列）に置く。変化は `onChange` 1 本で連へ上がる。
///
/// 列は最近使った順で、先頭が今の文書（今の文書にした・列に入れた文書を先頭へ置く）。列の中に仮の文書（見るだけの文書）を
/// 高々 1 つ持つ。仮で新しく開くと前の仮の文書を列から外すので、見て回るだけなら列が伸びない。仮の文書は常に未保存でない
/// ——未保存になった瞬間に普通の文書へ戻すので、入れ替えで中身を失わない。普通の文書は仮に戻らない。
@MainActor
final class EditorSession {
  /// 文書の開き方。入口ごとにどちらかを必ず選ぶ（どの入口が仮かは `docs/spec/editor/shell.md` の「仮の文書」が持つ）。
  enum OpenMode {
    /// 仮の文書として開く。既に開いていれば今の文書にするだけ（普通の文書は普通のまま）。
    case preview
    /// 普通の文書として開く。既に開いている仮の文書なら普通に変える。
    case pinned
  }

  private let surfaces: EditorSurfaces
  /// 人か制御 API が選んだ画面（選ぶまでは nil）。
  private(set) var chosenScreen: EditorScreen?
  /// 選ぶまでの画面（連が根から決める）。
  private(set) var defaultScreen: EditorScreen
  /// Files の開いている文書の列（最近使った順。先頭が今の文書）。
  private(set) var documents: [EditorDocument] = []
  /// Files の仮の文書（列の中の 1 つか nil）。
  private(set) var previewURL: URL?
  /// Changes の diff（作業ツリーかステージ済み）と PR の diff。
  private(set) var changesDiff: EditorDiff?
  private(set) var pullRequestDiff: EditorDiff?
  /// 文書ごとの根のサービスとの結線。文書と同寿命（閉じれば捨てる）。
  private var links: [ObjectIdentifier: DocumentLink] = [:]
  /// 画面・列・今の文書・仮の文書・diff・未保存の有無・「ディスクが変わった」の有無が変わった。
  var onChange: (() -> Void)?
  /// 本体のテキスト面が first responder になった／やめた。
  var onFocusChange: (() -> Void)?

  /// `chosenScreen` は復元した、選んでいた画面。
  init(surfaces: EditorSurfaces, defaultScreen: EditorScreen, chosenScreen: EditorScreen? = nil) {
    self.surfaces = surfaces
    self.defaultScreen = defaultScreen
    self.chosenScreen = chosenScreen
  }

  // MARK: - 画面と本体

  /// 今の画面——選んだ画面、無ければ選ぶまでの画面。
  var screen: EditorScreen { chosenScreen ?? defaultScreen }

  /// 画面を選ぶ（人と制御 API の入口が、開く操作と合わせて呼ぶ。開く操作そのものは画面に触れない）。
  func selectScreen(_ screen: EditorScreen) {
    guard chosenScreen != screen else { return }
    chosenScreen = screen
    onChange?()
  }

  /// 本体——画面の中身。Files は今の文書、Changes は Changes の diff、PR は PR の diff（無ければ空）。
  var body: EditorBody {
    switch screen {
    case .files: activeDocument.map(EditorBody.document) ?? .empty
    case .changes, .pullRequest: diff(on: screen).map(EditorBody.diff) ?? .empty
    }
  }

  /// 本体で編集している文書——本体が文書ならその文書、diff なら新しい側の文書（無ければ nil）。
  var editedDocument: EditorDocument? {
    switch body {
    case .document(let document): document
    case .diff(let diff): diff.document
    case .empty: nil
    }
  }

  // MARK: - 文書

  /// Files の今の文書（列の先頭）とその実体。
  var activeDocument: EditorDocument? { documents.first }
  var activeURL: URL? { activeDocument?.url }

  /// 列の中の実体 `url` の文書。
  func document(at url: URL) -> EditorDocument? { documents.first { $0.url == url } }

  /// 持っている文書——開いている文書の列と、列に無い Changes の diff の新しい側。
  var heldDocuments: [EditorDocument] {
    guard let diffDocument = changesDiff?.document,
      !documents.contains(where: { $0 === diffDocument })
    else { return documents }
    return documents + [diffDocument]
  }

  /// 文書 `document` を持っているか（開いている文書の列か、Changes の diff の新しい側）。
  func holds(_ document: EditorDocument) -> Bool {
    documents.contains { $0 === document } || changesDiff?.document === document
  }

  /// 閉じれば失われる文書（未保存の列。未保存の文書は必ず列に居る）。
  func documentsToDiscard() -> [EditorDocument] { documents.filter(\.isDirty) }

  /// 永続から戻す。保存の順で列の末尾へ開き（読めないパスは黙って落とす）、`preview` のパスの文書を仮にする（既に未保存なら
  /// 普通の文書にする）。既に居るものは壊さない——materialize より先に制御 API の `open_file` が文書を開いていれば、その文書の
  /// 開き方と今の文書を保つ。先に文書が無かったときだけ、`active` の文書を先頭（今の文書）へ移す——保存の順が最近使った順で
  /// なかった状態からも、今の文書が先頭で戻る。通知は 1 本にまとめる。
  func restore(paths: [String], active: String, preview: String?) {
    let before = documents.count
    let previewURL = preview.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    for path in paths {
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      guard document(at: url) == nil, let document = try? document(for: url) else { continue }
      documents.append(document)
      if self.previewURL == nil, url == previewURL { self.previewURL = url }
    }
    guard documents.count > before else { return }
    if before == 0 { moveToFront(URL(fileURLWithPath: active).resolvingSymlinksInPath()) }
    settlePreview()
    onChange?()
  }

  /// ファイルを `mode` で開いて今の文書にする。既に開いていれば今の文書にするだけ（`.pinned` なら仮の文書を普通に変える）。
  /// 仮で新しく開けば、前の仮の文書を列から外す（閉じる＋開くを 1 本の通知で）。文書が Changes の diff のために
  /// 既に開いていればそれを使う。読めない・UTF-8 でなければ文書のエラー、テキスト面を作れなければ
  /// `EditorSurfaceError.noMetalDevice` で失敗し、列・仮の文書は変わらない。文書の識別は symlink を解いた実体のパス——
  /// 保存は一時ファイルの rename なので、リンクのパスへ書くとリンク自体が通常ファイルに置き換わり実体へ届かない。同じ実体を
  /// 別の綴りで開いても文書が割れない。
  @discardableResult
  func open(_ url: URL, as mode: OpenMode) throws -> EditorDocument {
    let url = url.resolvingSymlinksInPath()
    if let existing = document(at: url) {
      focus(url, as: mode)
      return existing
    }
    let document = try document(for: url)
    place(document, as: mode)
    return document
  }

  /// 開いている文書 `url` を今の文書にする（`.pinned` なら仮の文書を普通に変える）。
  private func focus(_ url: URL, as mode: OpenMode) {
    let pins = mode == .pinned && previewURL == url
    guard pins || activeURL != url else { return }
    if pins { previewURL = nil }
    moveToFront(url)
    onChange?()
  }

  /// 新しい文書を列の先頭へ置いて今の文書にする（仮なら前の仮の文書を列から外す）。未保存の文書は、仮で頼まれても
  /// はじめから普通の文書にする——仮の文書は常に未保存でない。
  private func place(_ document: EditorDocument, as mode: OpenMode) {
    let mode = document.isDirty ? .pinned : mode
    var replaced: EditorDocument?
    if mode == .preview, let old = previewURL,
      let index = documents.firstIndex(where: { $0.url == old })
    {
      replaced = documents.remove(at: index)
    }
    documents.insert(document, at: 0)
    if mode == .preview { previewURL = document.url }
    release(replaced)
    onChange?()
  }

  /// 開いている文書 `url` を今の文書にする（列に無ければ何もしない）。
  func activate(_ url: URL) {
    guard document(at: url) != nil else { return }
    focus(url, as: .preview)
  }

  /// 列の文書 `url` を先頭へ移す（列に無ければ何もしない。通知しない）。
  private func moveToFront(_ url: URL) {
    guard let index = documents.firstIndex(where: { $0.url == url }), index > 0 else { return }
    documents.insert(documents.remove(at: index), at: 0)
  }

  /// 仮の文書を普通の文書にする（仮でなければ何もしない）。
  func pin(_ url: URL) {
    guard previewURL == url else { return }
    previewURL = nil
    onChange?()
  }

  /// 本体で編集している文書（`editedDocument`）を保存する。force でなければ、ディスクが変わっていれば失敗する
  /// （→ `EditorDocument.save`）。仮の文書は保存しても仮のまま。文書を使わない本体（ステージ済み diff など）では何もしない。
  func saveEdited(force: Bool = false) throws {
    try editedDocument?.save(force: force)
  }

  /// 文書 `url` を列から外す。未保存でも確認しない（確認は呼ぶ側の pane が出す）。今の文書だったなら、1 つ前に使った文書
  /// （列の次の文書）が今の文書になる。Changes の diff が使っていれば文書は生き続ける——ただし未保存のまま外す（保存しないで閉じる）なら、文書ごと
  /// 捨て、その diff を同じ対象で開き直す（ディスクの姿から読み直す）。
  func close(_ url: URL) {
    guard let index = documents.firstIndex(where: { $0.url == url }) else { return }
    let closed = documents.remove(at: index)
    if previewURL == url { previewURL = nil }
    if closed.isDirty, let diff = changesDiff, diff.document === closed {
      changesDiff = nil
      links[ObjectIdentifier(closed)] = nil
      changesDiff = try? makeDiff(diff.id)
    } else {
      release(closed)
    }
    onChange?()
  }

  /// 列から外した・diff が手放した文書を、もう持ち主（列・Changes の diff）が無ければ閉じる。
  private func release(_ document: EditorDocument?) {
    guard let document, !holds(document) else { return }
    links[ObjectIdentifier(document)] = nil
  }

  /// 実体 `url` の文書（開いていればそれ、無ければ読んで面を作って結線する。列に入るのは置いたとき）。
  private func document(for url: URL) throws -> EditorDocument {
    if let existing = document(at: url) { return existing }
    if let existing = changesDiff?.document, existing.url == url { return existing }
    let contents = try EditorDocument.read(url)
    guard let surface = surfaces.make() else { throw EditorSurfaceError.noMetalDevice }
    let document = EditorDocument(
      url: url, contents: contents, surface: surface, registry: surfaces.registry)
    own(document, link: DocumentLink(document: document))
    return document
  }

  /// 文書の通知をこのセッションへ結び、結線を持つ。未保存になった文書が列に無ければ（Changes の diff の中で編集した）、
  /// 列の 2 番目へ普通の文書として足す——直前に触った文書を今の文書のすぐ次に置く（列が空なら先頭で、今の文書になる。画面は
  /// 変えない）。
  private func own(_ document: EditorDocument, link: DocumentLink?) {
    document.onDirtyChange = { [weak self, weak document] _ in
      guard let self, let document else { return }
      if let diff = changesDiff, diff.document === document { diff.documentDirtyDidChange() }
      if document.isDirty, !documents.contains(where: { $0 === document }) {
        documents.insert(document, at: min(1, documents.count))
      }
      settlePreview()
      onChange?()
    }
    document.onDiskChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] _ in self?.onFocusChange?() }
    links[ObjectIdentifier(document)] = link
  }

  /// 仮の文書が未保存なら普通の文書にする（入れ替えで中身を失わない）。
  private func settlePreview() {
    guard let previewURL, document(at: previewURL)?.isDirty == true else { return }
    self.previewURL = nil
  }

  // MARK: - diff

  /// diff `id` を、その種類の画面の diff として開く（作業ツリー・ステージ済みは Changes、PR は PR）。同じ対象が開いていれば
  /// それを返し、違えば前の diff を手放して入れ替える。作業ツリー diff の新しい側はその実体の文書——開いていればそれを使い、
  /// 無ければ開いて持つ（列には出ない）。どの文書を使うかは diff が作業ツリーの姿から決め直す。テキスト面を作れなければ
  /// `EditorSurfaceError.noMetalDevice` で失敗し、前の diff は変わらない。
  @discardableResult
  func openDiff(_ id: EditorDiff.Key) throws -> EditorDiff {
    let screen = id.kind.screen
    if let current = diff(on: screen), current.id == id { return current }
    let diff = try makeDiff(id)
    setDiff(diff, on: screen)
    onChange?()
    return diff
  }

  /// 画面 `screen` の diff（Files には diff が無いので nil）。
  func diff(on screen: EditorScreen) -> EditorDiff? {
    switch screen {
    case .changes: changesDiff
    case .pullRequest: pullRequestDiff
    case .files: nil
    }
  }

  /// 画面 `screen` の diff を閉じる。
  func closeDiff(on screen: EditorScreen) {
    guard diff(on: screen) != nil else { return }
    setDiff(nil, on: screen)
    onChange?()
  }

  /// 画面 `screen` の diff を `diff` に替え、前の diff が使っていた文書を、持ち主が無くなれば閉じる。
  private func setDiff(_ diff: EditorDiff?, on screen: EditorScreen) {
    switch screen {
    case .changes:
      let previous = changesDiff
      changesDiff = diff
      release(previous?.document)
    case .pullRequest: pullRequestDiff = diff
    case .files: break
    }
  }

  /// diff を 2 つとも手放す（通知しない）。
  private func releaseDiffs() {
    setDiff(nil, on: .changes)
    setDiff(nil, on: .pullRequest)
  }

  private func makeDiff(_ id: EditorDiff.Key) throws -> EditorDiff {
    try EditorDiff(id: id, documents: diffDocuments, surfaces: surfaces)
  }

  /// diff が新しい側の文書を引く口と、替わったと知らせる口（このセッション）。
  private var diffDocuments: EditorDiff.Documents {
    EditorDiff.Documents(
      open: { [unowned self] url in try document(for: url) },
      switched: { [weak self] previous in self?.diffDocumentSwitched(from: previous) })
  }

  /// Changes の diff の新しい側の文書が替わった——前の文書は、列に無ければ閉じる。
  private func diffDocumentSwitched(from previous: EditorDocument?) {
    release(previous)
    onChange?()
  }

  // MARK: - 根と連

  /// 連の根が替わった。diff は「その根の Changes・PR」のものなので手放し、選ぶまでの画面を新しい根で決め直す（選んだ画面と
  /// 文書は保つ）。
  func rootDidChange(defaultScreen: EditorScreen) {
    releaseDiffs()
    self.defaultScreen = defaultScreen
    onChange?()
  }

  /// 別のセッションの開いている文書を、`other` の列の順で自分の列の末尾へ引き取る（cd で連が畳まれたとき）。`other` の diff は手放させる（行き先の
  /// 左の列には出どころの行が無い）。文書は実体ごとに勝ち負けを決める——自分に無ければ結線ごと移す。あれば、`other` の
  /// 文書だけが未保存のときに限り `other` の文書が勝ち、それ以外は自分の文書が勝つ（負けた側は未保存でも捨てる）。列は
  /// `other` の列の順に見て、同じ実体が自分の列にあれば捨て、無ければ末尾へ足す。仮の文書は自分に仮が無いときだけ仮のまま
  /// 移り、あれば普通の文書になる。足した後、列と Changes の diff の新しい側を勝った文書に揃える。今の文書（列の先頭）は
  /// 自分のものを保ち、自分の列が空だったなら `other` の今の文書になる。画面は変えない。`other` は通知なしに空になり、自分の変化は
  /// 1 本の通知で上げる。本体を見せていた pane は、呼ぶ前に手放しておく。
  func adopt(from other: EditorSession) {
    other.releaseDiffs()
    guard !other.documents.isEmpty else { return }
    let winners = settleDocuments(from: other)
    for document in other.documents where self.document(at: document.url) == nil {
      documents.append(document)
      if document.url == other.previewURL, previewURL == nil { previewURL = document.url }
    }
    replaceLosers(with: winners)
    var used = Set(documents.map(ObjectIdentifier.init))
    if let diffDocument = changesDiff?.document { used.insert(ObjectIdentifier(diffDocument)) }
    links = links.filter { used.contains($0.key) }
    other.documents = []
    other.links = [:]
    other.previewURL = nil
    settlePreview()
    changesDiff?.settle()
    onChange?()
  }

  /// `other` の文書の勝ち負けを実体ごとに決め、移る文書（自分に無いもの・勝ったもの）を結線ごと引き取る。戻り値は両方に
  /// あった実体の勝者。
  private func settleDocuments(from other: EditorSession) -> [URL: EditorDocument] {
    var winners: [URL: EditorDocument] = [:]
    for document in other.documents {
      let link = other.links[ObjectIdentifier(document)]
      let diffDocument = changesDiff?.document
      guard
        let mine = self.document(at: document.url)
          ?? (diffDocument?.url == document.url ? diffDocument : nil)
      else {
        own(document, link: link)
        continue
      }
      let theirs = document.isDirty && !mine.isDirty
      winners[document.url] = theirs ? document : mine
      if theirs { own(document, link: link) }
    }
    return winners
  }

  /// 列の文書と Changes の diff の新しい側を、その実体の勝者に揃える（列の文書は同じ位置で置き換える）。
  private func replaceLosers(with winners: [URL: EditorDocument]) {
    for (index, document) in documents.enumerated() {
      guard let winner = winners[document.url], winner !== document else { continue }
      documents[index] = winner
    }
    if let diff = changesDiff, let document = diff.document, let winner = winners[document.url],
      winner !== document
    {
      diff.replaceDocument(with: winner)
    }
  }

  /// テキスト面を描く用意を裏で始める（エディター面が初めて見えたとき。何度呼んでもよい）。
  func prepareSurfaces() {
    surfaces.prepare()
  }
}
