import Foundation
import OrbeEditorCore

/// エディター面のセッションへの入口（制御 API）と、エディターの復元単位。
extension TerminalTab {
  /// 閉じれば失われる文書（未保存の列）。閉じる・終了の確認が読む。
  func unsavedDocuments() -> [EditorDocument] {
    MainActor.assumeIsolated { editor.documentsToDiscard() }
  }

  /// エディターでファイルを普通のタブで開いて焦点の文書にする（制御 API の入口。エージェントが見せたファイルを人の次の
  /// クリックが入れ替えない）。読めない・UTF-8 でない・テキスト面を作れない（Metal の装置が無い）は throw。
  func openFile(_ url: URL) throws {
    _ = try MainActor.assumeIsolated { try editor.open(url, as: .pinned) }
  }

  /// エディターで diff を普通のタブで開いて焦点にする（制御 API の入口。エージェントが人に変更を見せる）。テキスト面を
  /// 作れない（Metal の装置が無い）は throw。
  func openDiff(_ id: EditorDiff.Key) throws {
    _ = try MainActor.assumeIsolated { try editor.openDiff(id, as: .pinned) }
  }

  /// 書くのは文書のタブだけ（diff のタブは戻さない）。焦点が diff のタブなら、diff のタブを除いた列でその位置にある文書の
  /// タブ——右隣、無ければ左隣。焦点のタブを閉じたときに焦点が移る規則（`EditorSession.close`）と同じ。
  func editorState() -> EditorState? {
    MainActor.assumeIsolated {
      let tabs = editor.tabs
      let files = tabs.compactMap { tab -> EditorDocument? in
        if case .document(let document) = tab { return document }
        return nil
      }
      let open =
        files.first.map { _ in
          let index = tabs.firstIndex { $0.id == editor.activeID } ?? 0
          let before = tabs[..<index].filter { if case .document = $0 { true } else { false } }
            .count
          let active = editor.activeDocument ?? files[min(before, files.count - 1)]
          let preview = editor.previewID.flatMap { id -> String? in
            guard case .document(let url) = id else { return nil }
            return url.path
          }
          return EditorState.OpenDocuments(
            open: files.map(\.url.path), active: active.url.path, preview: preview)
        } ?? pendingDocuments
      let state = EditorState(documents: open, search: view.editor.projectSearch.query)
      return state.isEmpty ? nil : state
    }
  }
}
