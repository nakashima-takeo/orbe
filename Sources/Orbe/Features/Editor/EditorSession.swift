import Foundation
import OrbeEditorCore

/// タブ 1 枚が持つ、開いた文書の列と焦点の文書。文書 1 つにテキスト面 1 つを対で持ち（開いてから
/// 閉じるまで）、切り替えは「どの文書の面を見せるか」を変えるだけなので undo・選択・スクロール・IME は
/// 文書ごとに残る。変化は `onChange` 1 本でタブへ上がる。
@MainActor
final class EditorSession {
  private let surfaces: EditorSurfaces
  private(set) var documents: [EditorDocument] = []
  private(set) var activeDocument: EditorDocument?
  /// 文書ごとの根のサービスとの結線。文書と同寿命（閉じれば捨てる）。
  private var links: [ObjectIdentifier: DocumentLink] = [:]
  /// 列・焦点・未保存の有無・「ディスクが変わった」の有無が変わった。
  var onChange: (() -> Void)?
  /// 文書のテキスト面が first responder になった／やめた。
  var onFocusChange: (() -> Void)?

  init(surfaces: EditorSurfaces) {
    self.surfaces = surfaces
  }

  /// 閉じれば失われる文書（未保存の列）。
  func documentsToDiscard() -> [EditorDocument] { documents.filter(\.isDirty) }

  /// 永続から戻す。順に開き（読めないパスは黙って落とす）、`active` が残っていればそれを、無ければ先頭を
  /// 焦点にする。既に居るものは壊さない——materialize より先に制御 API の `open_file` が文書を開いて
  /// いれば、その焦点を保つ（`activate` / `close` と同じく、居るものを確かめてから触る）。通知は 1 本にまとめる。
  func restore(paths: [String], active: String) {
    let saved = onChange
    onChange = nil
    defer { onChange = saved }
    let prior = activeDocument
    for path in paths { _ = try? open(URL(fileURLWithPath: path)) }
    guard !documents.isEmpty else { return }
    let activeURL = URL(fileURLWithPath: active).resolvingSymlinksInPath()
    activeDocument = prior ?? documents.first { $0.url == activeURL } ?? documents[0]
    saved?()
  }

  /// ファイルを開いて焦点にする。既に開いていれば焦点を移すだけ。読めない・UTF-8 でなければ文書のエラー、テキスト面を
  /// 作れなければ `EditorSurfaceError.noMetalDevice` で失敗し、列は変わらない。
  /// 文書の識別は symlink を解いた実体のパス——保存は一時ファイルの rename なので、リンクのパスへ書くと
  /// リンク自体が通常ファイルに置き換わり実体へ届かない。同じ実体を別の綴りで開いても文書が割れない。
  @discardableResult
  func open(_ url: URL) throws -> EditorDocument {
    let url = url.resolvingSymlinksInPath()
    if let existing = documents.first(where: { $0.url == url }) {
      activate(existing)
      return existing
    }
    let contents = try EditorDocument.read(url)
    guard let surface = surfaces.make() else { throw EditorSurfaceError.noMetalDevice }
    let document = EditorDocument(
      url: url, contents: contents, surface: surface, registry: surfaces.registry)
    document.onDirtyChange = { [weak self] _ in self?.onChange?() }
    document.onDiskChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] _ in self?.onFocusChange?() }
    links[ObjectIdentifier(document)] = DocumentLink(document: document)
    documents.append(document)
    activeDocument = document
    onChange?()
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

  /// 焦点の文書を保存する。force でなければ、ディスクが変わっていれば失敗する（→ `EditorDocument.save`）。
  func saveActive(force: Bool = false) throws {
    try activeDocument?.save(force: force)
  }

  /// 文書を閉じる（面も一緒に消える）。未保存でも黙って捨てる。焦点だった文書を閉じれば隣の文書へ。
  func close(_ document: EditorDocument) {
    guard let index = documents.firstIndex(where: { $0 === document }) else { return }
    documents.remove(at: index)
    links[ObjectIdentifier(document)] = nil
    if activeDocument === document {
      activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
    }
    onChange?()
  }
}
