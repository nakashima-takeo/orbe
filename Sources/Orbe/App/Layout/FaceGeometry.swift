import Foundation

/// 面の幾何（純粋関数）。配置と器の大きさから面 2 枚と間の矩形・取っ手（引き手・継ぎ目）の見え方・位置ドットを解き、
/// ⌘E・取っ手を押す／引く／離したときの結果の配置を返す。状態は正規形（`FaceLayout.normalized`）に
/// 限り、ここでは焦点を寄せ直さない。
///
/// 全面は器いっぱいを使う。分割中は両面がカードになり、器の内側の余白と面と面の間を空けて並ぶ——分けるのは
/// 器から余白 2 つと間を除いた幅（分割の幅）で、割合をその幅で解いて両面に幅が残るときだけ分割になる。
/// カードの形の計算は `frames` と、その逆の `ratio(seamX:width:)` だけが持つ。
enum FaceGeometry {
  /// 分割中、焦点の面の中身の上辺へ重ねる焦点の印の高さ（場所は取らない）。
  static let focusBand: CGFloat = 2
  /// これ未満の移動はクリック扱い。
  static let dragThreshold: CGFloat = 4
  /// 取っ手を離したとき、面がこれより狭ければ端ぎりぎりに寄せたとみなして閉じる（使えない細い面を残さない）。
  static let closeEdge: CGFloat = 40

  /// 取っ手の見え方: 隠れた面の側の縁に出る引き手か、分割中の継ぎ目（面と面の間）。
  enum HandleLook: Equatable {
    case notch(Face)
    case seam
  }

  /// 位置ドットの 3 態: 隠れている / 見えていて非焦点 / 見えていて焦点。
  enum DotState: Equatable {
    case off, on, focus
  }

  struct FaceDots: Equatable {
    let editor: DotState
    let terminal: DotState
  }

  /// chrome と取っ手が読む投影。器の `layout()` がこれの差分で更新を起こす。
  struct Projection: Equatable {
    let dots: FaceDots
    let handleLook: HandleLook
    let isSplit: Bool
  }

  /// 置き方: 表示中のエディターの割合と、カードで描くか。
  struct Placement: Equatable {
    var ratio: Double
    var cards: Bool
  }

  /// 置き方を器の大きさで解いた、面 2 枚と間の矩形（器の座標・上が原点）。
  struct Frames: Equatable {
    let editor: CGRect
    let terminal: CGRect
    let gap: CGRect
  }

  /// 配置を器の大きさで解いた結果。
  struct Resolved: Equatable {
    let faces: FaceLayout
    let size: CGSize
    /// 静止しているときの置き方（割合は実効の値。分割でなければ 0 か 1）。
    let placement: Placement
    let frames: Frames
    let projection: Projection
    var width: CGFloat { size.width }
    var editorWidth: CGFloat { frames.editor.width }
    var terminalWidth: CGFloat { frames.terminal.width }
    var isSplit: Bool { projection.isSplit }
  }

  private static var inset: CGFloat { Theme.Layout.faceSplitInset }
  private static var gap: CGFloat { Theme.Layout.faceSplitGap }

  /// 分割中に両面で分ける幅（器 − 余白 2 つ − 間）。
  static func splitWidth(_ width: CGFloat) -> CGFloat {
    max(0, width - 2 * inset - gap)
  }

  /// 割合を分割の幅で解き、両面に幅が残れば分割、残らなければ割合の近い側の全面にする。
  static func resolve(_ faces: FaceLayout, size: CGSize) -> Resolved {
    let size = CGSize(width: max(0, size.width), height: max(0, size.height))
    let s = splitWidth(size.width)
    let eS = (faces.editorRatio * s).rounded()
    let placement =
      eS > 0 && eS < s
      ? Placement(ratio: faces.editorRatio, cards: true)
      : Placement(ratio: faces.editorRatio < 0.5 ? 0 : 1, cards: false)
    let f = frames(placement, size: size)
    let eW = f.editor.width
    let tW = f.terminal.width
    let look: HandleLook = eW <= 0 ? .notch(.editor) : tW <= 0 ? .notch(.terminal) : .seam
    func dot(_ face: Face, visible: Bool) -> DotState {
      !visible ? .off : faces.focus == face ? .focus : .on
    }
    return Resolved(
      faces: faces, size: size, placement: placement, frames: f,
      projection: Projection(
        dots: FaceDots(
          editor: dot(.editor, visible: eW > 0), terminal: dot(.terminal, visible: tW > 0)),
        handleLook: look, isSplit: eW > 0 && tW > 0))
  }

  /// 置き方の矩形。カードなら余白と間を空けて分割の幅を割合で分け、そうでなければ器いっぱいを割合で分ける
  /// （間は境に立つ幅 0 の矩形）。
  static func frames(_ p: Placement, size: CGSize) -> Frames {
    let w = size.width
    let h = size.height
    let ratio = CGFloat(p.ratio)
    guard p.cards else {
      let eW = (ratio * w).rounded()
      return Frames(
        editor: CGRect(x: 0, y: 0, width: eW, height: h),
        terminal: CGRect(x: eW, y: 0, width: w - eW, height: h),
        gap: CGRect(x: eW, y: 0, width: 0, height: h))
    }
    let s = splitWidth(w)
    let eW = (ratio * s).rounded()
    let cardHeight = max(0, h - 2 * inset)
    return Frames(
      editor: CGRect(x: inset, y: inset, width: eW, height: cardHeight),
      terminal: CGRect(x: inset + eW + gap, y: inset, width: s - eW, height: cardHeight),
      gap: CGRect(x: inset + eW, y: inset, width: gap, height: cardHeight))
  }

  /// `frames` の間の中央 `x` を割合へ戻す（分割の幅に収める）。分割の幅が無ければ nil。
  static func ratio(seamX x: CGFloat, width: CGFloat) -> Double? {
    let s = splitWidth(width)
    guard s > 0 else { return nil }
    return Double(min(max(x - inset - gap / 2, 0), s) / s)
  }

  /// ⌘E: 分割中は焦点の往復。それ以外は端末 ⇄ エディターの全面切替。
  static func toggle(_ g: Resolved) -> FaceLayout {
    if g.isSplit {
      return FaceLayout(
        editorRatio: g.faces.editorRatio, focus: g.faces.focus == .editor ? .terminal : .editor)
    }
    return g.placement.ratio >= 1 ? .terminalOnly : FaceLayout(editorRatio: 1, focus: .editor)
  }

  /// 引き手・間の点を押した: 隣が隠れていれば全開、自分が隠れていれば戻る、分割中は焦点側で全面。
  static func handleClick(_ g: Resolved) -> FaceLayout {
    if g.editorWidth <= 0 { return FaceLayout(editorRatio: 1, focus: .editor) }
    if g.terminalWidth <= 0 { return .terminalOnly }
    return g.faces.focus == .editor ? FaceLayout(editorRatio: 1, focus: .editor) : .terminalOnly
  }

  /// 取っ手を引いている間。`x` は間の中央の求める位置（器の座標）で、分割の幅に収めた連続値が割合になる。
  /// `g0` は掴んだ瞬間の配置を今の器の大きさで解いた結果（器が広がってもドラッグは今の幅で続く）。焦点は動かさない——
  /// 焦点の面が幅 0 になるときだけ残る面へ移る（正規形）。分割の幅が無い器では配置を変えない。結果は正規形。
  static func drag(from g0: Resolved, x: CGFloat) -> FaceLayout {
    guard let ratio = ratio(seamX: x, width: g0.width) else { return g0.faces }
    return FaceLayout(editorRatio: ratio, focus: g0.faces.focus).normalized
  }

  /// 取っ手を離した: 分割の幅の上で端に寄せた面（`closeEdge` 未満）は閉じ、それ以外はドラッグの値をそのまま確定する。
  /// 閉じる側が焦点の面なら残る面へ焦点が移る（全面の配置は正規形でその面が焦点）。分割の幅が無い器では配置を変えない。
  static func release(_ faces: FaceLayout, width: CGFloat) -> FaceLayout {
    let s = splitWidth(width)
    guard s > 0 else { return faces }
    let eW = (faces.editorRatio * s).rounded()
    if eW < closeEdge { return .terminalOnly }
    if s - eW < closeEdge { return FaceLayout(editorRatio: 1, focus: .editor) }
    return faces
  }
}
