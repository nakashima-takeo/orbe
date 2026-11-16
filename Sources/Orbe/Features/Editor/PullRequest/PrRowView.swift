import AppKit

/// PR のパネルの列の 1 行（区分の見出し・欠けの行・コミット・フォルダ・ファイル）を描く。寸法と色は見本 PrReviewPanel の値。
/// 文字は CoreText の行で持ち、中身が変わったときだけ組み直す。行の中の部品（確認済みのチェック・ツリー / リストの印）は
/// 位置を `control(at:)` で答える。
final class PrRowView: ListRowView {
  /// 確認済みのチェックの姿。
  enum Check: Equatable {
    case off, on, partial
  }

  enum Content {
    case section(Section)
    case note(TextLine)
    case commit(message: TextLine, sha: TextLine)
    case folder(Folder)
    case file(File)
  }

  struct Section {
    let isOpen: Bool
    let label: TextLine
    /// コミットの件数のバッジ（変更ファイルの見出しは nil）。
    let count: TextLine?
    /// 変更ファイルの見出しの「N/M 確認済み」と、ツリーで見せているか（変更ファイルの見出しだけ）。
    let viewed: TextLine?
    let asTree: Bool?
  }

  struct Folder {
    let check: Check
    let depth: Int
    let isOpen: Bool
    let name: TextLine
    let count: TextLine
    let dimmed: Bool
  }

  struct File {
    let check: Check
    let depth: Int
    let chip: FileChip
    let chipText: TextLine
    let name: TextLine
    let directory: TextLine?
    let badge: TextLine
    let badgeKind: GitStatus.Badge
    let dimmed: Bool
  }

  private(set) var content: Content?
  /// 描いている中身の同一性（同じなら組み直さない）。
  private var key: String?
  /// 部品の説明の文（ツリー表示・リスト表示）。
  private var helps: [PrControl: String] = [:]

  /// 最初の行を描く前に 1 度だけ要る準備（色の解決・字体の初回の字組み）。
  static func prepare(for appearance: NSAppearance) {
    _ = RowColors.of(appearance)
    _ = ScmRowColors.of(appearance)
    _ = PrRowColors.of(appearance)
    TextLine.prepare([
      Theme.Typography.editorScmSection, Theme.Typography.editorScmCount,
      Theme.Typography.editorScmFile, Theme.Typography.editorScmDirectory,
      Theme.Typography.editorScmCommit, Theme.Typography.editorPrCount,
      Theme.Typography.editorBadge,
    ])
  }

  /// 行 `item` を見せる。中身の同一性（`key`）が変わったときだけ字を組み直す。
  func show(_ item: PrLayout.Item, facts: Facts, language: Language, emoji: NSFont?) {
    let key = Self.key(item, facts, language) + (emoji.map { "\u{0}\($0.fontName)" } ?? "")
    guard key != self.key else { return }
    self.key = key
    content = Self.content(item, facts, language, emoji)
    helps = Self.helps(language)
    setAccessibilityLabel(Self.label(item, facts, language))
    needsDisplay = true
  }

  // MARK: - 寸法

  /// 確認済みのチェックの枠（フォルダ・ファイル）。
  func checkRect() -> NSRect? {
    switch content {
    case .folder, .file:
      let size = Theme.Layout.editorPrCheckbox
      return NSRect(x: 12, y: snap(bounds.midY - size / 2), width: size, height: size)
    default: return nil
    }
  }

  /// 変更ファイルの見出しの「ツリー表示」「リスト表示」の枠。
  func toggleRects() -> [(PrControl, NSRect)] {
    guard case .section(let section) = content, section.asTree != nil else { return [] }
    let size = Theme.Layout.editorPrViewToggle
    let list = NSRect(
      x: bounds.width - 12 - size, y: snap(bounds.midY - size / 2), width: size, height: size)
    let tree = list.offsetBy(dx: -(size + 1), dy: 0)
    return [(.tree, tree), (.list, list)]
  }

  override func control(at point: NSPoint) -> ListRowControl? {
    if let rect = checkRect(), rect.insetBy(dx: -3, dy: -3).contains(point) {
      return ListRowControl(id: PrControl.viewed.rawValue, frame: rect, isEnabled: true)
    }
    return toggleRects().first { $0.1.contains(point) }.map {
      ListRowControl(id: $0.0.rawValue, frame: $0.1, isEnabled: true)
    }
  }

  override func help(at point: NSPoint) -> String? {
    toggleRects().first { $0.1.contains(point) }.flatMap { helps[$0.0] }
  }

  /// ポインタが乗っている部分が変わったときだけ描き直す（行の地・印の地）。
  override func pointerDidChange(from old: NSPoint?) {
    let hovered = { (point: NSPoint?) -> (row: Bool, toggle: Int?) in
      guard let point else { return (false, nil) }
      return (self.bounds.contains(point), self.toggleRects().firstIndex { $0.1.contains(point) })
    }
    if hovered(old) != hovered(pointer) { needsDisplay = true }
  }

  var isHovered: Bool {
    guard let pointer else { return false }
    return bounds.contains(pointer)
  }

  // MARK: - 描画

  override func drawContent(_ colors: RowColors, in context: CGContext) {
    let pr = PrRowColors.of(effectiveAppearance)
    let scm = ScmRowColors.of(effectiveAppearance)
    switch content {
    case .section(let section): draw(section, colors, scm, pr, in: context)
    case .note(let text):
      text.draw(at: 20, top: top(text), width: max(0, bounds.width - 32), colors.tertiary, context)
    case .commit(let message, let sha): draw(message: message, sha: sha, colors, pr, in: context)
    case .folder(let folder): draw(folder, colors, scm, pr, in: context)
    case .file(let file): draw(file, colors, scm, pr, in: context)
    case nil: break
    }
  }
}

/// PR のパネルの行だけが使う色（行に共通の色は `RowColors`、ソース管理と同じ色は `ScmRowColors`）。外観ごとに 1 度だけ解いて
/// 使い回す。
struct PrRowColors {
  /// コミットの点（accentBright）。
  let dot: CGColor
  /// 字下げの線（hairline .08）。
  let guide: CGColor
  /// チェックの付いた地と枠（accent）・レ点と横線（accentCheckStroke）・付いていない枠（hairline .22）と地（sunk .25）。
  let checkOn: CGColor
  let checkMark: CGColor
  let checkBorder: CGColor
  let checkGround: CGColor
  /// 選んでいる「ツリー表示」「リスト表示」の地（fill .10）と印（chromeText）。
  let toggleOn: CGColor
  let toggleOnGlyph: CGColor

  @MainActor private static let resolved = PerAppearance { PrRowColors() }

  @MainActor static func of(_ appearance: NSAppearance) -> PrRowColors { resolved(appearance) }

  private init() {
    dot = Theme.Color.accentBright.cgColor
    guide = EditorStyle.hairline(0.08).cgColor
    checkOn = Theme.Color.accentPrimary.cgColor
    checkMark = Theme.Color.accentCheckStroke.cgColor
    checkBorder = EditorStyle.hairline(0.22).cgColor
    checkGround = EditorStyle.sunk(0.25).cgColor
    toggleOn = EditorStyle.fill(0.10).cgColor
    toggleOnGlyph = Theme.Color.textPrimary.cgColor
  }
}
