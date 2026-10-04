import Foundation
import OrbeEditorCore

/// タブ 1 枚が持つ、開いた文書の列と焦点の文書。文書 1 つにテキスト面 1 つを対で持ち（開いてから
/// 閉じるまで）、切り替えは「どの文書の面を見せるか」を変えるだけなので undo・選択・スクロールは
/// 文書ごとに残る。変化は `onChange` 1 本でタブへ上がる。
///
/// 列の中に仮の文書（見るだけのファイル）を高々 1 つ持つ。仮で開くと今の仮の文書をその位置で入れ替えるので、見て回る
/// だけなら列が伸びない。仮の文書は常に未保存でない——未保存になった瞬間に普通の文書へ戻すので、入れ替えで中身を失わない。
/// 普通の文書は仮に戻らない。
@MainActor
final class EditorSession {
  /// 開き方。入口ごとにどちらかを必ず選ぶ（どの入口が仮かは `docs/spec/editor/shell.md` の「仮のタブ」が持つ）。
  enum OpenMode {
    /// 仮の文書として開く。既に開いていれば焦点を移すだけ（普通の文書は普通のまま）。
    case preview
    /// 普通の文書として開く。既に開いている仮の文書なら普通に変える。
    case pinned
  }

  private let surfaces: EditorSurfaces
  private(set) var documents: [EditorDocument] = []
  private(set) var activeDocument: EditorDocument?
  /// 仮の文書（列の中の 1 つか nil）。
  private(set) var preview: EditorDocument?
  /// 文書ごとの根のサービスとの結線。文書と同寿命（閉じれば捨てる）。
  private var links: [ObjectIdentifier: DocumentLink] = [:]
  /// 列・焦点・仮の文書・未保存の有無・「ディスクが変わった」の有無が変わった。
  var onChange: (() -> Void)?
  /// 文書のテキスト面が first responder になった／やめた。
  var onFocusChange: (() -> Void)?

  init(surfaces: EditorSurfaces) {
    self.surfaces = surfaces
  }

  /// 閉じれば失われる文書（未保存の列）。
  func documentsToDiscard() -> [EditorDocument] { documents.filter(\.isDirty) }

  /// 永続から戻す。順に開き（読めないパスは黙って落とす）、`preview` のパスの文書を仮にし、`active` が残っていればそれを、
  /// 無ければ先頭を焦点にする。既に居るものは壊さない——materialize より先に制御 API の `open_file` が文書を開いて
  /// いれば、その文書の開き方と焦点を保つ。通知は 1 本にまとめる。
  func restore(paths: [String], active: String, preview: String?) {
    let previewURL = preview.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    for path in paths {
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      guard !documents.contains(where: { $0.url == url }), let document = try? make(url) else {
        continue
      }
      documents.append(document)
      if self.preview == nil, url == previewURL { self.preview = document }
    }
    guard !documents.isEmpty else { return }
    let activeURL = URL(fileURLWithPath: active).resolvingSymlinksInPath()
    activeDocument = activeDocument ?? documents.first { $0.url == activeURL } ?? documents[0]
    onChange?()
  }

  /// ファイルを `mode` で開いて焦点にする。既に開いていれば焦点を移すだけ（`.pinned` なら仮の文書を普通に変える）。仮で
  /// 新しく開けば、今の仮の文書をその位置で入れ替える（閉じる＋開くを 1 本の通知で）。読めない・UTF-8 でなければ文書の
  /// エラー、テキスト面を作れなければ `EditorSurfaceError.noMetalDevice` で失敗し、列・仮の文書は変わらない。
  /// 文書の識別は symlink を解いた実体のパス——保存は一時ファイルの rename なので、リンクのパスへ書くと
  /// リンク自体が通常ファイルに置き換わり実体へ届かない。同じ実体を別の綴りで開いても文書が割れない。
  @discardableResult
  func open(_ url: URL, as mode: OpenMode) throws -> EditorDocument {
    let url = url.resolvingSymlinksInPath()
    if let existing = documents.first(where: { $0.url == url }) {
      let pins = mode == .pinned && existing === preview
      guard pins || activeDocument !== existing else { return existing }
      if pins { preview = nil }
      activeDocument = existing
      onChange?()
      return existing
    }
    let document = try make(url)
    if mode == .preview, let old = preview,
      let index = documents.firstIndex(where: { $0 === old })
    {
      documents[index] = document
      links[ObjectIdentifier(old)] = nil
    } else {
      documents.append(document)
    }
    if mode == .preview { preview = document }
    activeDocument = document
    onChange?()
    return document
  }

  /// 文書を読み、面を作って結線する（列には入れない）。
  private func make(_ url: URL) throws -> EditorDocument {
    let contents = try EditorDocument.read(url)
    guard let surface = surfaces.make() else { throw EditorSurfaceError.noMetalDevice }
    let document = EditorDocument(
      url: url, contents: contents, surface: surface, registry: surfaces.registry)
    document.onDirtyChange = { [weak self, weak document] dirty in
      guard let self else { return }
      if dirty, let document, document === preview { preview = nil }
      onChange?()
    }
    document.onDiskChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] _ in self?.onFocusChange?() }
    links[ObjectIdentifier(document)] = DocumentLink(document: document)
    return document
  }

  /// テキスト面を描く用意を裏で始める（エディター面が初めて見えたとき。何度呼んでもよい）。
  func prepareSurfaces() {
    surfaces.prepare()
  }

  func activate(_ document: EditorDocument) {
    guard activeDocument !== document, documents.contains(where: { $0 === document }) else {
      return
    }
    activeDocument = document
    onChange?()
  }

  /// 仮の文書を普通の文書にする（仮でなければ何もしない）。
  func pin(_ document: EditorDocument) {
    guard document === preview else { return }
    preview = nil
    onChange?()
  }

  /// 焦点の文書を保存する。force でなければ、ディスクが変わっていれば失敗する（→ `EditorDocument.save`）。仮の文書は
  /// 保存しても仮のまま。
  func saveActive(force: Bool = false) throws {
    try activeDocument?.save(force: force)
  }

  /// 文書を閉じる（面も一緒に消える）。未保存でも黙って捨てる。焦点だった文書を閉じれば隣の文書へ。
  func close(_ document: EditorDocument) {
    guard let index = documents.firstIndex(where: { $0 === document }) else { return }
    documents.remove(at: index)
    links[ObjectIdentifier(document)] = nil
    if preview === document { preview = nil }
    if activeDocument === document {
      activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
    }
    onChange?()
  }
}
