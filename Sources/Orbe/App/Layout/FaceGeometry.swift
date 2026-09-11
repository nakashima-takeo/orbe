import Foundation

/// 面の幾何（純粋関数）。配置と器の幅から各面の px・分割可否・背の見え方・位置ドットを解き、
/// ⌘E・背のクリック／ドラッグの結果の配置を返す。状態は正規形（`FaceLayout.normalized`）に限り、
/// ここでは焦点を寄せ直さない。
enum FaceGeometry {
  /// 背（面の継ぎ目の帯）の幅。
  static let spine: CGFloat = 14
  /// 面の上辺の焦点帯の高さ（分割中の焦点の面だけ色が付き、それ以外は透明で常に確保する）。
  static let focusBand: CGFloat = 2
  /// 分割が成立する内容幅（背を除く）。未満なら焦点側 1 枚へ吸着する（配置の記憶は残る）。
  static let splitMin: CGFloat = 1060
  /// 面の中身の最小幅。面が縮んでも中身は潰れず錨側へ滑り出る。
  static let editorMin: CGFloat = 400
  static let terminalMin: CGFloat = 660
  /// 背のドラッグの吸着: close 未満で閉じ、min まで押し上げ、keep（端末の最小幅）を残す。
  enum Snap {
    static let close: CGFloat = 200
    static let min: CGFloat = 400
    static let keep: CGFloat = 660
  }
  /// これ未満の移動はクリック扱い。
  static let dragThreshold: CGFloat = 4

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
    let canSplit: Bool
    /// 幅不足の吸着後の実効のエディター割合。
    let effectiveRatio: Double
    let editorWidth: CGFloat
    let terminalWidth: CGFloat
    let projection: Projection
    var isSplit: Bool { projection.isSplit }
  }

  static func resolve(_ faces: FaceLayout, width: CGFloat) -> Resolved {
    let cw = max(0, width - spine)
    let canSplit = cw >= splitMin
    let e = faces.editorRatio
    let eEff = (e > 0 && e < 1 && !canSplit) ? (faces.focus == .editor ? 1 : 0) : e
    let eW = (eEff * cw).rounded()
    let tW = cw - eW
    let look: SpineLook = eW <= 0 ? .hidden(.editor) : tW <= 0 ? .hidden(.terminal) : .grip
    func dot(_ face: Face, visible: Bool) -> DotState {
      !visible ? .off : faces.focus == face ? .focus : .on
    }
    return Resolved(
      faces: faces, contentWidth: cw, canSplit: canSplit, effectiveRatio: eEff,
      editorWidth: eW, terminalWidth: tW,
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
    return g.effectiveRatio >= 1 ? .terminalOnly : FaceLayout(editorRatio: 1, focus: .editor)
  }

  /// 背を動かさずに離した: 隣が隠れていれば全開、自分が隠れていれば戻る、分割中は焦点側で全面。
  static func spineClick(_ faces: FaceLayout, _ g: Resolved) -> FaceLayout {
    if g.editorWidth <= 0 { return FaceLayout(editorRatio: 1, focus: .editor) }
    if g.terminalWidth <= 0 { return .terminalOnly }
    return faces.focus == .editor ? FaceLayout(editorRatio: 1, focus: .editor) : .terminalOnly
  }

  /// 背のドラッグ。`x` は器の左端からの距離、`g0` は掴んだ瞬間の解決結果。結果は正規形。
  static func drag(_ faces: FaceLayout, from g0: Resolved, x: CGFloat) -> FaceLayout {
    let c = g0.contentWidth
    guard c > 0 else { return faces }
    let w = c < splitMin ? (x < c / 2 ? 0 : c) : snap(x, c)
    let focus: Face =
      w <= 0 ? .terminal : w >= c ? .editor : (g0.editorWidth > 0 ? g0.faces.focus : .editor)
    return FaceLayout(editorRatio: Double(w / c), focus: focus).normalized
  }

  /// 吸着。`hi = max(min, c − keep)` なので c ≥ 1060 では設計どおり（400 / c−660 / 中点）、それより
  /// 狭くても単調。
  static func snap(_ raw: CGFloat, _ c: CGFloat) -> CGFloat {
    let hi = max(Snap.min, c - Snap.keep)
    if raw < Snap.close { return 0 }
    if raw < Snap.min { return Snap.min }
    if raw <= hi { return raw }
    return raw < (hi + c) / 2 ? hi : c
  }
}
