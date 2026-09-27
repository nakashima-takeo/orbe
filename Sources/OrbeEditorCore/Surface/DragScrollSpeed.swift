import CoreGraphics

/// 選択のドラッグが本文の外へ出たときの自動スクロールの速さ（VS Code の `TopBottomDragScrolling` /
/// `LeftRightDragScrolling`）。両方のテキスト面が同じ式を使う。
public enum DragScrollSpeed {
  /// 速さ（単位/秒）。外れた距離 `outside` と見えている量 `visible` を、どちらも同じ単位（縦は行・横は全角の字）で数える。
  public static func speed(outside: CGFloat, visible: CGFloat) -> CGFloat {
    outside <= 1.5
      ? max(30, visible * (1 + outside))
      : outside <= 3 ? max(60, visible * (2 + outside)) : max(200, visible * (7 + outside))
  }
}
