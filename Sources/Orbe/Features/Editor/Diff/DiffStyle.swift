import AppKit
import OrbeEditorCore

/// diff の面の表示の構成と行の型（色は `Theme` のトークン）。行の型の番号は `DiffRows` が指す。字は型に依らず構文の色で、
/// 追加・削除は行の地と記号の列の ＋ / − で見分ける。
enum DiffStyle {
  /// 行の型の番号。
  static let added = 0
  static let removed = 1
  static let pad = 2
  /// スレッドのある行（追加・削除・文脈）。記号は元の型のまま、地だけを替える。
  static let addedThread = 3
  static let removedThread = 4
  static let contextThread = 5

  /// 型 `style`（nil は文脈）の行に、スレッドがあるときの型。
  static func thread(_ style: Int?) -> Int {
    switch style {
    case added: addedThread
    case removed: removedThread
    default: contextThread
    }
  }

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

  /// PR の diff のインラインと並列の片側——ほかの diff の構成に、行の右端のコメント追加の印を足したもの。
  static let pullRequestInline = commenting(inline)
  static let pullRequestSide = commenting(side)

  private static func commenting(_ presentation: SurfacePresentation) -> SurfacePresentation {
    var presentation = presentation
    presentation.trailingMark = PrCommentStyle.trailingMark
    return presentation
  }

  /// 追加（diff.added の地と ＋）・削除（diff.removed の地と −）・詰め物（淡い塗り）と、スレッドのある追加・削除・文脈の行
  /// （地は accent の α `editorPrThreadRow`）。
  private static let lineStyles: [LineStyle] =
    [
      LineStyle(
        background: Theme.Color.editorDiffAddedRow, sign: "+", signColor: Theme.Color.diffAdded),
      LineStyle(
        background: Theme.Color.editorDiffRemovedRow, sign: "−",
        signColor: Theme.Color.diffRemoved),
      LineStyle(background: EditorStyle.fill(Theme.Opacity.editorDiffPad)),
      LineStyle(
        background: Theme.Color.editorPrThreadRow, sign: "+", signColor: Theme.Color.diffAdded),
      LineStyle(
        background: Theme.Color.editorPrThreadRow, sign: "−", signColor: Theme.Color.diffRemoved),
      LineStyle(background: Theme.Color.editorPrThreadRow),
    ]
}
