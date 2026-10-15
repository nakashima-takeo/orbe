import Foundation

/// 面の幾何（純粋関数）。境の位置 hx と、左右の縁から離れた度合い sL・sR（形）から、両面・両面の間・取っ手の矩形と
/// 取っ手の形の進み具合を解き、⌘E・取っ手を押す／離したときの結果の配置を返す。状態は正規形（`FaceLayout.normalized`）に
/// 限り、ここでは焦点を寄せ直さない。
///
/// hx は取っ手の左端で、0（端末だけ）…MAX（エディターだけ。MAX = 器の幅 − 取っ手の幅）。割合は hx ÷ MAX。形の目標は
/// 縁から `morphDistance` 離れるまでに 0（引き手）から 1（継ぎ目）へ移り、両面の間は形に応じて 0〜取っ手の幅だけ開く。
enum FaceGeometry {
  /// 分割中、焦点の面の中身の上辺へ重ねる焦点の印の高さ（場所は取らない）。
  static let focusBand: CGFloat = 2
  /// これ未満の移動はクリック扱い。
  static let dragThreshold: CGFloat = 4
  /// 縁からこの距離で、形の目標が引き手から継ぎ目へ移り切る。
  static let morphDistance: CGFloat = 56
  /// 離したとき、勢いで滑った先がこの距離より端に近ければ閉じる。
  static let releaseSnap: CGFloat = 24
  /// 離したときの勢いを、この秒数だけ先へ投影する。
  static let releaseProjection: CGFloat = 0.12
  /// 離したときの速度は、この秒数より新しい標本から測る。
  static let releaseVelocityWindow: CFTimeInterval = 0.08

  private static var handleWidth: CGFloat { Theme.Layout.faceHandle }

  /// 位置ドットの 3 態: 隠れている / 見えていて非焦点 / 見えていて焦点。
  enum DotState: Equatable {
    case off, on, focus
  }

  struct FaceDots: Equatable {
    let editor: DotState
    let terminal: DotState
  }

  /// chrome が読む投影。器の `layout()` がこれの差分で更新を起こす。
  struct Projection: Equatable {
    let dots: FaceDots
    let isSplit: Bool
  }

  /// 境の位置と形。sL・sR は左右の縁から離れた度合い（0 = 引き手、1 = 継ぎ目。ばねで追うので範囲を越えうる）。
  struct Shape: Equatable {
    var hx: CGFloat
    var sL: CGFloat
    var sR: CGFloat
  }

  /// 形を器の大きさで解いた矩形（器の座標・上が原点）と、取っ手の形の進み具合 `t`（0 = 引き手、1 = 継ぎ目）。
  struct Frames: Equatable {
    let editor: CGRect
    let terminal: CGRect
    /// 両面の間（継ぎ目の地で埋める列）。
    let gap: CGRect
    let handle: CGRect
    let t: CGFloat
    /// 取っ手が左寄り（エディターの引き手）か。
    let edgeOnLeft: Bool
  }

  /// 配置を器の大きさで解いた結果。
  struct Resolved: Equatable {
    let faces: FaceLayout
    let size: CGSize
    let shape: Shape
    let frames: Frames
    let projection: Projection
    var width: CGFloat { size.width }
    var editorWidth: CGFloat { frames.editor.width }
    var terminalWidth: CGFloat { frames.terminal.width }
    var isSplit: Bool { projection.isSplit }
  }

  /// hx の取りうる最大（器の幅 − 取っ手の幅）。
  static func maxPosition(_ width: CGFloat) -> CGFloat {
    max(0, width - handleWidth)
  }

  /// 位置が決める形の目標（左右）。器が取っ手より狭ければ端末だけの形。
  static func targets(_ hx: CGFloat, width: CGFloat) -> (l: CGFloat, r: CGFloat) {
    let maxX = maxPosition(width)
    guard maxX > 0 else { return (0, 1) }
    return (clamp(hx / morphDistance), clamp((maxX - hx) / morphDistance))
  }

  /// 静止の配置: 割合を点に丸めた hx と、その目標の形で解き、面の境も点に丸める（面と中身をピクセルに揃える）。
  static func resolve(_ faces: FaceLayout, size: CGSize) -> Resolved {
    let size = CGSize(width: max(0, size.width), height: max(0, size.height))
    let hx = (CGFloat(faces.editorRatio) * maxPosition(size.width)).rounded()
    let (l, r) = targets(hx, width: size.width)
    return resolve(faces, shape: Shape(hx: hx, sL: l, sR: r), size: size, snapped: true)
  }

  /// 形を解く。`snapped` なら面の境を点に丸める（静止のとき）。引いている間・動いている間は丸めない。
  static func resolve(
    _ faces: FaceLayout, shape: Shape, size: CGSize, snapped: Bool = false
  ) -> Resolved {
    let f = frames(shape, size: size, snapped: snapped)
    let editorVisible = f.editor.width > 0
    let terminalVisible = f.terminal.width > 0
    func dot(_ face: Face, visible: Bool) -> DotState {
      !visible ? .off : faces.focus == face ? .focus : .on
    }
    return Resolved(
      faces: faces, size: size, shape: shape, frames: f,
      projection: Projection(
        dots: FaceDots(
          editor: dot(.editor, visible: editorVisible),
          terminal: dot(.terminal, visible: terminalVisible)),
        isSplit: editorVisible && terminalVisible))
  }

  /// 形の矩形。エディターは取っ手の右端から縁へ近づくほど取っ手の下へ潜り、端末は左端から同じく潜る——両面の間は
  /// 形に応じて 0〜取っ手の幅。取っ手の高さは引き手の高さから全高へ伸びる。`snapped` なら面の境を点に丸める。
  static func frames(_ s: Shape, size: CGSize, snapped: Bool = false) -> Frames {
    let w = size.width
    let h = size.height
    let cl = clamp(s.sL)
    let cr = clamp(s.sR)
    let t = min(cl, cr)
    func edge(_ x: CGFloat) -> CGFloat { min(max(snapped ? x.rounded() : x, 0), w) }
    let editorRight = edge(s.hx + handleWidth * (1 - cr))
    let terminalLeft = edge(s.hx + handleWidth * cl)
    let notch = Theme.Layout.faceNotchHeight
    let handleHeight = min(notch + (h - notch) * t, h)
    return Frames(
      editor: CGRect(x: 0, y: 0, width: editorRight, height: h),
      terminal: CGRect(x: terminalLeft, y: 0, width: w - terminalLeft, height: h),
      gap: CGRect(x: editorRight, y: 0, width: max(0, terminalLeft - editorRight), height: h),
      handle: CGRect(x: s.hx, y: (h - handleHeight) / 2, width: handleWidth, height: handleHeight),
      t: t, edgeOnLeft: s.hx < maxPosition(w) / 2)
  }

  /// hx の割合。取っ手より狭い器では nil。
  static func ratio(hx: CGFloat, width: CGFloat) -> Double? {
    let maxX = maxPosition(width)
    guard maxX > 0 else { return nil }
    return Double(hx / maxX)
  }

  /// 離した: 勢いで `releaseProjection` 秒先まで滑った位置が端から `releaseSnap` 以内なら、その端（0 か MAX）を返して
  /// 閉じる。それ以外はその場に留まる（nil）。
  static func release(hx: CGFloat, velocity: CGFloat, width: CGFloat) -> CGFloat? {
    let maxX = maxPosition(width)
    let projected = hx + velocity * releaseProjection
    if projected < releaseSnap { return 0 }
    if projected > maxX - releaseSnap { return maxX }
    return nil
  }

  /// ⌘E: 分割中は焦点の往復。それ以外は端末 ⇄ エディターの全面切替。
  static func toggle(_ g: Resolved) -> FaceLayout {
    if g.isSplit {
      return FaceLayout(
        editorRatio: g.faces.editorRatio, focus: g.faces.focus == .editor ? .terminal : .editor)
    }
    return g.editorWidth > 0 ? .terminalOnly : FaceLayout(editorRatio: 1, focus: .editor)
  }

  /// 取っ手を押した: 隣が隠れていれば全開、自分が隠れていれば戻る、分割中は焦点側で全面。
  static func handleClick(_ g: Resolved) -> FaceLayout {
    if g.editorWidth <= 0 { return FaceLayout(editorRatio: 1, focus: .editor) }
    if g.terminalWidth <= 0 { return .terminalOnly }
    return g.faces.focus == .editor ? FaceLayout(editorRatio: 1, focus: .editor) : .terminalOnly
  }

  private static func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
}
