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
  /// 背を離したとき、面がこれより狭ければ端に寄せたとみなして閉じる。
  static let closeEdge: CGFloat = 200

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
  static func toggle(_ faces: FaceLayout, _ g: Resolved) -> FaceLayout {
    if g.isSplit {
      return FaceLayout(
        editorRatio: faces.editorRatio, focus: faces.focus == .editor ? .terminal : .editor)
    }
    return faces.editorRatio >= 1 ? .terminalOnly : FaceLayout(editorRatio: 1, focus: .editor)
  }

  /// 背を動かさずに離した: 隣が隠れていれば全開、自分が隠れていれば戻る、分割中は焦点側で全面。
  static func spineClick(_ faces: FaceLayout, _ g: Resolved) -> FaceLayout {
    if g.editorWidth <= 0 { return FaceLayout(editorRatio: 1, focus: .editor) }
    if g.terminalWidth <= 0 { return .terminalOnly }
    return faces.focus == .editor ? FaceLayout(editorRatio: 1, focus: .editor) : .terminalOnly
  }

  /// 背のドラッグ中。`x` は器の左端からの距離で、0…内容幅に収めた連続値がそのままエディター幅になる。
  /// `g0` は掴んだ瞬間の解決結果。結果は正規形。
  static func drag(_ faces: FaceLayout, from g0: Resolved, x: CGFloat) -> FaceLayout {
    let c = g0.contentWidth
    guard c > 0 else { return faces }
    let w = min(max(x, 0), c)
    let focus: Face =
      w <= 0 ? .terminal : w >= c ? .editor : (g0.editorWidth > 0 ? g0.faces.focus : .editor)
    return FaceLayout(editorRatio: Double(w / c), focus: focus).normalized
  }

  /// 背を離した: 端に寄せた面（`closeEdge` 未満）は閉じ、それ以外はドラッグの値をそのまま確定する。
  static func release(_ faces: FaceLayout, contentWidth c: CGFloat) -> FaceLayout {
    let eW = (faces.editorRatio * c).rounded()
    if eW < closeEdge { return .terminalOnly }
    if c - eW < closeEdge { return FaceLayout(editorRatio: 1, focus: .editor) }
    return faces
  }
}
