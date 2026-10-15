import AppKit
import OrbeEditorCore

/// diff の面の表示の構成と行の型（色は `Theme` のトークン）。行の型の番号は `DiffRows` が指す。字は型に依らず構文の色で、
/// 追加・削除は行の地と記号の列の ＋ / − で見分ける。
enum DiffStyle {
  /// 行の型の番号。
  static let added = 0
  static let removed = 1
  static let pad = 2

  /// インライン——番号 2 列（旧・新）・記号の列・印の列なし・ミニマップなし。値は 1 度だけ作る（色の値の同一性で面が
  /// 同じ構成の押し直しを見分ける）。
  static let inline =
    SurfacePresentation(
      showsMinimap: false, numberColumns: 2, numberWidth: Theme.Layout.editorDiffNumber,
      numberTrailing: Theme.Layout.editorDiffNumberTrailingInline,
      signWidth: Theme.Layout.editorDiffSign, showsMarks: false, lineStyles: lineStyles)

  /// 並列の片側——番号 1 列・記号の列なし・印の列なし・ミニマップなし。
  static let side =
    SurfacePresentation(
      showsMinimap: false, numberWidth: Theme.Layout.editorDiffNumber,
      numberTrailing: Theme.Layout.editorDiffNumberTrailingSide, showsMarks: false,
      lineStyles: lineStyles)

  /// 追加（diff.added の地と ＋）・削除（diff.removed の地と −）・詰め物（淡い塗り）。
  private static let lineStyles: [LineStyle] =
    [
      LineStyle(
        background: Theme.Color.editorDiffAddedRow, sign: "+", signColor: Theme.Color.diffAdded),
      LineStyle(
        background: Theme.Color.editorDiffRemovedRow, sign: "−",
        signColor: Theme.Color.diffRemoved),
      LineStyle(background: EditorStyle.fill(Theme.Opacity.editorDiffPad)),
    ]
}
