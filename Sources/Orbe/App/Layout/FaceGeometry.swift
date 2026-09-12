import Foundation

/// 面の幾何（純粋関数）。配置と器の幅から各面の px・背の見え方・位置ドットを解き、
/// ⌘E・背のクリック／ドラッグ／離したときの結果の配置を返す。状態は正規形（`FaceLayout.normalized`）に
/// 限り、ここでは焦点を寄せ直さない。面の幅に最小値は無く、どの器の幅でも分割できる。
enum FaceGeometry {
  /// 背（面の継ぎ目の帯）の幅。
  static let spine: CGFloat = 14
  /// 面の上辺の焦点帯の高さ（分割中の焦点の面だけ色が付き、それ以外は透明で常に確保する）。
  static let focusBand: CGFloat = 2
  /// これ未満の移動はクリック扱い。
  static let dragThreshold: CGFloat = 4
  /// 背を離したとき、面がこれより狭ければ端ぎりぎりに寄せたとみなして閉じる（使えない細い面を残さない）。
  static let closeEdge: CGFloat = 40

  /// 背の見え方: 隠れた面の印（その面のキー色）か、両面が見えているときのグリップ。
  enum SpineLook: Equatable {
    case hidden(Face)
    case grip
  }

  /// 位置ドットの 3 態: 隠れている / 見えていて非焦点 / 見えていて焦点。
  enum DotState: Equatable {
    case off, on, focus
  }

  struct FaceDots: Equatable {
    let editor: DotState
    let terminal: DotState
  }

  /// chrome と背が読む投影。器の `layout()` がこれの差分で更新を起こす。
  struct Projection: Equatable {
    let dots: FaceDots
    let spineLook: SpineLook
    let isSplit: Bool
  }

  /// 配置を幅で解いた結果。
  struct Resolved: Equatable {
    let faces: FaceLayout
    /// 内容幅（背を除く）。
    let contentWidth: CGFloat
    let editorWidth: CGFloat
    let terminalWidth: CGFloat
    let projection: Projection
    var isSplit: Bool { projection.isSplit }
  }

  static func resolve(_ faces: FaceLayout, width: CGFloat) -> Resolved {
    let cw = max(0, width - spine)
    let eW = (faces.editorRatio * cw).rounded()
    let tW = cw - eW
    let look: SpineLook = eW <= 0 ? .hidden(.editor) : tW <= 0 ? .hidden(.terminal) : .grip
    func dot(_ face: Face, visible: Bool) -> DotState {
      !visible ? .off : faces.focus == face ? .focus : .on
    }
    return Resolved(
      faces: faces, contentWidth: cw, editorWidth: eW, terminalWidth: tW,
      projection: Projection(
        dots: FaceDots(
          editor: dot(.editor, visible: eW > 0), terminal: dot(.terminal, visible: tW > 0)),
        spineLook: look, isSplit: eW > 0 && tW > 0))
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

  /// 背を動かさずに離した: 隣が隠れていれば全開、自分が隠れていれば戻る、分割中は焦点側で全面。
  static func spineClick(_ g: Resolved) -> FaceLayout {
    if g.editorWidth <= 0 { return FaceLayout(editorRatio: 1, focus: .editor) }
    if g.terminalWidth <= 0 { return .terminalOnly }
    return g.faces.focus == .editor ? FaceLayout(editorRatio: 1, focus: .editor) : .terminalOnly
  }

  /// 背のドラッグ中。`x` は器の左端からの距離で、0…内容幅に収めた連続値がそのままエディター幅になる。
  /// `g0` は掴んだ瞬間の配置を今の器の幅で解いた結果（器が広がってもドラッグは今の幅で続く）。焦点は動かさない——焦点の面が幅 0 になるときだけ残る面へ移る
  /// （正規形）。結果は正規形。
  static func drag(from g0: Resolved, x: CGFloat) -> FaceLayout {
    let c = g0.contentWidth
    guard c > 0 else { return g0.faces }
    let w = min(max(x, 0), c)
    return FaceLayout(editorRatio: Double(w / c), focus: g0.faces.focus).normalized
  }

  /// 背を離した: 端に寄せた面（`closeEdge` 未満）は閉じ、それ以外はドラッグの値をそのまま確定する。
  /// 閉じる側が焦点の面なら残る面へ焦点が移る（全面の配置は正規形でその面が焦点）。
  static func release(_ faces: FaceLayout, contentWidth c: CGFloat) -> FaceLayout {
    let eW = (faces.editorRatio * c).rounded()
    if eW < closeEdge { return .terminalOnly }
    if c - eW < closeEdge { return FaceLayout(editorRatio: 1, focus: .editor) }
    return faces
  }
}
