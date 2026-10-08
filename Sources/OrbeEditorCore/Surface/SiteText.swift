/// 面の中の編集の場（本文と区画の入力欄）の、文の出どころ。面の編集係は場の文をこの口だけで変え・読む——本文の場は文書
/// （`TextSurfaceDelegate`）を包み、入力欄の場は `ZoneTextField` が実装する。
@MainActor
public protocol SiteText: AnyObject {
  /// 編集の束を当てる。束は重ならない昇順の列で、どの範囲も束の前の文の座標で書く（`TextSurfaceDelegate` の
  /// `didChange` と同じ）。
  func apply(_ edits: [TextEdit])
  /// 今の写し（文・役割の並び・版）。結ばれていなければ nil。
  var content: SurfaceContent? { get }
}
