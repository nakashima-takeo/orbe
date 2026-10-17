import AppKit

/// 行の中で描く印（`EditorGlyphs` を CGPath にしたもの。寸法ごとに 1 度だけ作る）。
enum ScmGlyphShape: Hashable {
  case chevron, chevronOpen, openFile, discard, plus, minus, refresh, branch

  private var glyph: EditorGlyphs.Glyph {
    switch self {
    case .chevron, .chevronOpen: EditorGlyphs.chevron
    case .openFile: EditorGlyphs.openFile
    case .discard: EditorGlyphs.discard
    case .plus: EditorGlyphs.plus
    case .minus: EditorGlyphs.minus
    case .refresh: EditorGlyphs.refresh
    case .branch: EditorGlyphs.branch
    }
  }

  struct Path {
    let path: CGPath
    let lineWidth: CGFloat
    let fills: Bool
  }

  @MainActor private static var cache: [Self: [CGFloat: Path]] = [:]

  @MainActor func path(size: CGFloat) -> Path {
    if let path = Self.cache[self]?[size] { return path }
    let glyph = self.glyph
    let k = size / glyph.viewBox
    let path = CGMutablePath()
    for part in glyph.parts(k) { path.addPath(part.path.cgPath) }
    var shaped: CGPath = path
    if self == .chevronOpen {
      var turn = CGAffineTransform(translationX: size / 2, y: size / 2).rotated(by: .pi / 2)
        .translatedBy(x: -size / 2, y: -size / 2)
      shaped = path.copy(using: &turn) ?? path
    }
    let made = Path(path: shaped, lineWidth: glyph.stroke * k, fills: glyph.fills)
    Self.cache[self, default: [:]][size] = made
    return made
  }
}

/// ソース管理の行だけが使う色（行に共通の色は `RowColors`）。外観ごとに 1 度だけ解いて使い回す。
struct ScmRowColors {
  let icon: CGColor
  let accent: CGColor
  /// 行のボタンの押せない字（editor.text .3）。
  let disabled: CGColor
  /// 見出しのツールの押せない字（muted .35。SwiftUI の見出しのツール `ScmToolButton` と同じ）。
  let toolDisabled: CGColor
  /// 見本 chromeBg（点の輪と中抜きの点の地）。
  let ground: CGColor
  let headerHover: CGColor
  let fileHover: CGColor
  let toolHover: CGColor
  let buttonHover: CGColor
  let countStrong: CGColor
  let graphLine: CGColor
  let branchGround: CGColor
  let branchBorder: CGColor
  let localRefGround: CGColor
  let localRefBorder: CGColor
  let remoteRefGround: CGColor
  let remoteRefBorder: CGColor
  private let badges: [GitStatus.Badge: CGColor]

  @MainActor private static let resolved = PerAppearance { ScmRowColors() }

  @MainActor static func of(_ appearance: NSAppearance) -> ScmRowColors { resolved(appearance) }

  private init() {
    icon = Theme.Color.editorIcon.cgColor
    accent = Theme.Color.accentBright.cgColor
    disabled = Theme.Color.editorText.withAlphaComponent(0.3).cgColor
    toolDisabled = Theme.Color.textMuted.withAlphaComponent(0.35).cgColor
    ground = Theme.Color.bgBase.cgColor
    headerHover = EditorStyle.fill(0.04).cgColor
    fileHover = EditorStyle.fill(0.045).cgColor
    toolHover = EditorStyle.fill(0.08).cgColor
    buttonHover = EditorStyle.fill(0.10).cgColor
    countStrong = Theme.Color.accentPrimary.withAlphaComponent(0.35).cgColor
    graphLine = EditorStyle.hairline(0.12).cgColor
    branchGround = EditorStyle.sunk(0.35).cgColor
    branchBorder = EditorStyle.hairline(0.10).cgColor
    localRefGround = Theme.Color.accentPrimary.withAlphaComponent(0.18).cgColor
    localRefBorder = Theme.Color.accentPrimary.withAlphaComponent(0.4).cgColor
    remoteRefGround = EditorStyle.fill(0.06).cgColor
    remoteRefBorder = EditorStyle.hairline(0.14).cgColor
    badges = [
      .modified: Theme.Color.diffModified.cgColor, .added: Theme.Color.diffAdded.cgColor,
      .untracked: Theme.Color.diffAdded.cgColor, .conflicted: Theme.Color.conflict.cgColor,
    ]
  }

  /// バッジの字と、その行の名前の色（エクスプローラーと同じ）。
  func badge(_ badge: GitStatus.Badge) -> CGColor { badges[badge]! }
}
