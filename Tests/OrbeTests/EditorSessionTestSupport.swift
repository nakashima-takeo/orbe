import Foundation
import OrbeEditorCore

@testable import Orbe

/// 文書のタブの操作の略記（テスト）。製品はタブの識別で操作する。
@MainActor
extension EditorSession {
  func activate(_ document: EditorDocument) { activate(.document(document.url)) }
  func pin(_ document: EditorDocument) { pin(.document(document.url)) }
  func close(_ document: EditorDocument) { close(.document(document.url)) }

  /// 仮のタブが文書のタブなら、その文書。
  var preview: EditorDocument? {
    guard case .document(let url)? = previewID, case .document(let document)? = tab(.document(url))
    else { return nil }
    return document
  }
}

@MainActor
extension EditorShellModel {
  /// diff の見せ方を既定（インライン）にした写し。
  func update(from session: EditorSession, root: String) {
    update(from: session, root: root, diffMode: .inline)
  }
}

@MainActor
extension TabFacesView {
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
