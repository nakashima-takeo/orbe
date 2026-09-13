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
  /// 焦点の文書のテキスト面が first responder になった。
  var onFocus: (() -> Void)?

  init(surfaces: EditorSurfaces) {
    self.surfaces = surfaces
  }

  var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }

  /// ファイルを開いて焦点にする。既に開いていれば焦点を移すだけ（本文は面にあるものが正）。
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
    let document = EditorDocument(
      url: url, contents: contents, surface: surfaces.make(contents.text),
      registry: surfaces.registry)
    document.onDirtyChange = { [weak self] _ in self?.onChange?() }
    document.onDiskChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] focused in if focused { self?.onFocus?() } }
    links[ObjectIdentifier(document)] = DocumentLink(document: document)
    documents.append(document)
    activeDocument = document
    onChange?()
    return document
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
