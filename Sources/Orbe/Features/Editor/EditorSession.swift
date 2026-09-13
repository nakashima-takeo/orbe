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
  /// 列・焦点・未保存の有無が変わった。
  var onChange: (() -> Void)?
  /// 焦点の文書のテキスト面が first responder になった。
  var onFocus: (() -> Void)?

  init(surfaces: EditorSurfaces) {
    self.surfaces = surfaces
  }

  var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }

  /// ファイルを開いて焦点にする。既に開いていれば焦点を移すだけ（本文は面にあるものが正）。
  @discardableResult
  func open(_ url: URL) throws -> EditorDocument {
    if let existing = documents.first(where: { $0.url == url }) {
      activate(existing)
      return existing
    }
    let text = try EditorDocument.read(url)
    let document = EditorDocument(
      url: url, surface: surfaces.make(text), registry: surfaces.registry)
    document.onDirtyChange = { [weak self] _ in self?.onChange?() }
    document.onFocusChange = { [weak self] focused in if focused { self?.onFocus?() } }
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

  func save(_ document: EditorDocument) throws {
    try document.save()
  }

  func saveActive() throws {
    guard let activeDocument else { return }
    try save(activeDocument)
  }

  /// 文書を閉じる（面も一緒に消える）。未保存でも黙って捨てる。焦点だった文書を閉じれば隣の文書へ。
  func close(_ document: EditorDocument) {
    guard let index = documents.firstIndex(where: { $0 === document }) else { return }
    documents.remove(at: index)
    if activeDocument === document {
      activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
    }
    onChange?()
  }
}
