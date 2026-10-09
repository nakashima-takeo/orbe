import OrbeEditorCore

/// 面に載せる見え方——表示の構成・並び（差し込みの出どころを含む）・編集できるか・文書の行差分の上限を 1 つの値にした
/// もの。ファイルタブの見え方（`code`）と diff の見え方があり、丸ごと置き換える（付け外しを 1 つずつ行わない——共有の外し
/// 忘れ・古い並びの残りを構造で無くす）。並列の相手の面は diff が持ち、diff を見せるのをやめるときに閉じる。
struct SurfaceLook {
  var presentation: SurfacePresentation
  var rows: SurfaceRows
  var isEditable: Bool
  var hunkLimit: Int

  /// ファイルタブの見え方——コードの構成・並びなし・編集できる・ガターの上限。
  static let code = SurfaceLook(
    presentation: .code, rows: SurfaceRows(), isEditable: true,
    hunkLimit: LineDiff.maximumComparedLines)

  /// 面 `surface`（と、それを持つ文書 `document`）に載せる。同じ値の押し直しは面と文書が何もしない。並びは構成の後に置く
  /// （差し込みはミニマップを出さない構成の面にだけ置ける）。外すときは逆に並びを先に外す。
  @MainActor
  func apply(to surface: any TextSurface, document: EditorDocument?) {
    if presentation.showsMinimap {
      surface.setRows(rows)
      surface.setPresentation(presentation)
    } else {
      surface.setPresentation(presentation)
      surface.setRows(rows)
    }
    surface.isEditable = isEditable
    document?.hunkLimit = hunkLimit
  }
}
