import Foundation

/// 面の幾何（純粋関数）。配置と器の幅から各面の px・取っ手（引き手・継ぎ目）の見え方・位置ドットを解き、
/// ⌘E・取っ手を押す／引く／離したときの結果の配置を返す。状態は正規形（`FaceLayout.normalized`）に
/// 限り、ここでは焦点を寄せ直さない。面の幅に最小値は無く、どの器の幅でも分割できる。
enum FaceGeometry {
  /// 分割中、焦点の面の中身の上辺へ重ねる焦点の印の高さ（場所は取らない）。
  static let focusBand: CGFloat = 2
  /// これ未満の移動はクリック扱い。
  static let dragThreshold: CGFloat = 4
  /// 取っ手を離したとき、面がこれより狭ければ端ぎりぎりに寄せたとみなして閉じる（使えない細い面を残さない）。
  static let closeEdge: CGFloat = 40

  /// 取っ手の見え方: 隠れた面の側の縁に出る引き手か、分割中の継ぎ目。
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

  /// 配置を幅で解いた結果。
  struct Resolved: Equatable {
    let faces: FaceLayout
    /// 器の幅。
    let width: CGFloat
    let editorWidth: CGFloat
    let terminalWidth: CGFloat
    let projection: Projection
    var isSplit: Bool { projection.isSplit }
  }

  static func resolve(_ faces: FaceLayout, width: CGFloat) -> Resolved {
    let w = max(0, width)
    let eW = (faces.editorRatio * w).rounded()
    let tW = w - eW
    let look: HandleLook = eW <= 0 ? .notch(.editor) : tW <= 0 ? .notch(.terminal) : .seam
    func dot(_ face: Face, visible: Bool) -> DotState {
      !visible ? .off : faces.focus == face ? .focus : .on
    }
    return Resolved(
      faces: faces, width: w, editorWidth: eW, terminalWidth: tW,
      projection: Projection(
        dots: FaceDots(
          editor: dot(.editor, visible: eW > 0), terminal: dot(.terminal, visible: tW > 0)),
        handleLook: look, isSplit: eW > 0 && tW > 0))
  }

  /// ⌘E: 分割中は焦点の往復。それ以外は端末 ⇄ エディターの全面切替。
  static func toggle(_ g: Resolved) -> FaceLayout {
    let faces = g.faces
    if g.isSplit {
      return FaceLayout(
        editorRatio: faces.editorRatio, focus: faces.focus == .editor ? .terminal : .editor)
    }
    return faces.editorRatio >= 1 ? .terminalOnly : FaceLayout(editorRatio: 1, focus: .editor)
  }

  /// 引き手・グリップを押した: 隣が隠れていれば全開、自分が隠れていれば戻る、分割中は焦点側で全面。
  static func handleClick(_ g: Resolved) -> FaceLayout {
    if g.editorWidth <= 0 { return FaceLayout(editorRatio: 1, focus: .editor) }
    if g.terminalWidth <= 0 { return .terminalOnly }
    return g.faces.focus == .editor ? FaceLayout(editorRatio: 1, focus: .editor) : .terminalOnly
  }

  /// 取っ手を引いている間。`x` は境（エディター幅）の求める位置で、0…器の幅に収めた連続値がそのままエディター幅になる。
  /// `g0` は掴んだ瞬間の配置を今の器の幅で解いた結果（器が広がってもドラッグは今の幅で続く）。焦点は動かさない——焦点の面が幅 0 になるときだけ残る面へ移る
  /// （正規形）。結果は正規形。
  static func drag(from g0: Resolved, x: CGFloat) -> FaceLayout {
    let c = g0.width
    guard c > 0 else { return g0.faces }
    let w = min(max(x, 0), c)
    return FaceLayout(editorRatio: Double(w / c), focus: g0.faces.focus).normalized
  }

  /// 取っ手を離した: 端に寄せた面（`closeEdge` 未満）は閉じ、それ以外はドラッグの値をそのまま確定する。
  /// 閉じる側が焦点の面なら残る面へ焦点が移る（全面の配置は正規形でその面が焦点）。
  static func release(_ faces: FaceLayout, width c: CGFloat) -> FaceLayout {
    let eW = (faces.editorRatio * c).rounded()
    if eW < closeEdge { return .terminalOnly }
    if c - eW < closeEdge { return FaceLayout(editorRatio: 1, focus: .editor) }
    return faces
  }
}
