import Foundation
import OrbeEditorCore

@testable import Orbe

/// 開いている文書の操作の略記（テスト）。製品は文書の実体の URL で操作する。
@MainActor
extension EditorSession {
  func activate(_ document: EditorDocument) { activate(document.url) }
  func pin(_ document: EditorDocument) { pin(document.url) }
  func close(_ document: EditorDocument) { close(document.url) }

  /// 文書を今の文書にして Files の画面を選ぶ（タブを押したのと同じ）。
  func show(_ document: EditorDocument) {
    activate(document.url)
    selectScreen(.files)
  }

  /// 仮の文書。
  var preview: EditorDocument? { previewURL.flatMap(document(at:)) }
}

@MainActor
extension EditorShellModel {
  /// diff の見せ方を既定（インライン）にした写し。
  func update(from session: EditorSession, root: String) {
    update(from: session, root: root, diffMode: .inline)
  }
}

@MainActor
extension GroupFacesView {
  /// diff の見せ方を既定にして窓の環境を配る。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState
  ) {
    configure(
      translucency: translucency, localization: localization, fontResolver: fontResolver,
      sidebar: sidebar, diffModes: EditorDiffModeState())
  }
}

@MainActor
extension EditorPaneView {
  /// diff の見せ方を既定にして窓の環境を配る。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState
  ) {
    configure(
      translucency: translucency, localization: localization, fontResolver: fontResolver,
      sidebar: sidebar, diffModes: EditorDiffModeState())
  }
}
