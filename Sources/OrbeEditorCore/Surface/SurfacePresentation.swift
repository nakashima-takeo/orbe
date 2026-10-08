/// 面の表示の構成（→ `TextSurface.setPresentation`）。面を作るときの見え方（字・行高・色・俯瞰の寸法）とは別に、面の
/// 生涯の途中でも置き直せる。置かなければ `code`。
public struct SurfacePresentation: Equatable, Sendable {
  /// ミニマップを出すか。出さない面は、右列が縦スクロールバーだけになる。差し込み（`SurfaceRows`）を受け付けるのは、
  /// 出さない面だけ。
  public var showsMinimap: Bool

  public init(showsMinimap: Bool = true) {
    self.showsMinimap = showsMinimap
  }

  /// コードの面の構成。
  public static let code = SurfacePresentation()
}
