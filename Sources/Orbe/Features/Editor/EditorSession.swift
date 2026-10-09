import Foundation
import OrbeEditorCore

/// タブ 1 枚（端末のタブ）が持つ、エディター面のタブの列（文書のタブと diff のタブ）と焦点のタブ。文書は実体の URL ごとに
/// 1 つで、テキスト面 1 つを開いてから閉じるまで対で持ち、その文書を使うタブ（ファイルタブと、それを新しい側に使う作業
/// ツリー diff）が持ち主になる——最後の持ち主が離れたら閉じる。切り替えは「どのタブの本体を見せるか」を変えるだけなので、
/// undo・選択・スクロールは文書ごとに残る（同じ文書のファイルタブと作業ツリー diff は、同じ面の位置・選択・undo を共有
/// する）。変化は `onChange` 1 本でタブへ上がる。
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
  /// その実体の文書——開いていればそれを使い、無ければ開いて持つ（タブには出ない）。作業ツリーのパスがシンボリック
  /// リンク・UTF-8 でない・読めないなら、文書を開かず「表示できない」の diff になる。テキスト面を作れなければ
  /// `EditorSurfaceError.noMetalDevice` で失敗する。
  @discardableResult
  func openDiff(_ id: EditorDiff.Key, as mode: OpenMode) throws -> EditorDiff {
    if case .diff(let existing)? = tab(.diff(id)) {
      focus(.diff(id), as: mode)
      return existing
    }
    let working = try id.kind == .workingTree ? workingSide(of: id) : nil
    let diff = EditorDiff(id: id, working: working, surfaces: surfaces)
    place(.diff(diff), as: mode)
    return diff
  }

  /// 作業ツリー diff の新しい側。
  private func workingSide(of id: EditorDiff.Key) throws -> EditorDiff.WorkingSide {
    let url = id.url
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return .missing
    }
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      return .unavailable(.symlink)
    }
    do {
      return .document(try document(for: url.resolvingSymlinksInPath()))
    } catch EditorSurfaceError.noMetalDevice {
      throw EditorSurfaceError.noMetalDevice
    } catch EditorDocumentError.notUTF8 {
      return .unavailable(.notText)
    } catch {
      return .unavailable(.failed)
    }
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
    onChange?()
  }

  /// 実体 `url` の文書（開いていればそれ、無ければ読んで面を作って結線する。列に入るのは、使うタブを置いたとき）。
  private func document(for url: URL) throws -> EditorDocument {
    if let existing = documents.first(where: { $0.url == url }) { return existing }
    let contents = try EditorDocument.read(url)
    guard let surface = surfaces.make() else { throw EditorSurfaceError.noMetalDevice }
    let document = EditorDocument(
      url: url, contents: contents, surface: surface, registry: surfaces.registry)
    document.onDirtyChange = { [weak self] _ in
      guard let self else { return }
      settlePreview()
      onChange?()
    }
    document.onDiskChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] _ in self?.onFocusChange?() }
    links[ObjectIdentifier(document)] = DocumentLink(document: document)
    return document
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
