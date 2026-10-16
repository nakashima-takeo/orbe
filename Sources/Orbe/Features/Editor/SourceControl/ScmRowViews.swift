import AppKit

/// ソース管理の列の 1 行（区分見出し・ファイル行・ブランチの器・コミット・さらに表示）を描く。寸法と色は見本 ScmPanel の値。
/// 文字は CoreText の行で持ち、中身が変わったときだけ組み直す。行の中のボタンは位置を `control(at:)` で答え、ポインタが
/// 乗ったボタンに地を付ける。
final class ScmRowView: ListRowView {
  struct Button {
    let control: ScmControl
    let glyph: ScmGlyphShape
    let isEnabled: Bool
    let help: String
  }

  enum Content {
    case header(Header)
    case file(File)
    case branch(Branch)
    case commit(Commit)
    case more(TextLine)
  }

  struct Header {
    let section: ScmSection
    let isOpen: Bool
    let label: TextLine
    let count: TextLine?
    let buttons: [Button]
  }

  struct File {
    let chip: FileChip
    let chipText: TextLine
    let name: TextLine
    let directory: TextLine
    let badge: TextLine
    let badgeKind: GitStatus.Badge
    let buttons: [Button]
  }

  struct Branch {
    let name: TextLine
    let divergence: TextLine?
  }

  struct Commit {
    let subject: TextLine
    let isPushed: Bool
    let isFirst: Bool
    let isLast: Bool
    /// 札（local が先）と、それぞれの文字。
    let refs: [(label: TextLine, isLocal: Bool)]
  }

  private(set) var content: Content?
  /// 描いている中身の同一性（同じなら組み直さない）。
  private var key: String?

  static let rowHeight = Theme.Layout.editorScmRow

  /// 最初の行を描く前に 1 度だけ要る準備（色の解決・字体の初回の字組み）。
  static func prepare(for appearance: NSAppearance) {
    _ = RowColors.of(appearance)
    _ = ScmRowColors.of(appearance)
    TextLine.prepare([
      Theme.Typography.editorScmSection, Theme.Typography.editorScmCount,
      Theme.Typography.editorScmFile, Theme.Typography.editorScmDirectory,
      Theme.Typography.editorBadge, Theme.Typography.editorScmCommit,
      Theme.Typography.editorScmRef, Theme.Typography.editorScmBranch,
      Theme.Typography.editorScmMore,
    ])
  }

  func show(_ item: ScmLayout.Item, language: Language, emoji: NSFont?) {
    let key = Self.key(item, language) + (emoji.map { "\u{0}\($0.fontName)" } ?? "")
    guard key != self.key else { return }
    self.key = key
    content = Self.content(item, language, emoji)
    setAccessibilityLabel(Self.label(item, language))
    needsDisplay = true
  }

  // MARK: - 寸法

  /// 中身の帯（グラフの見出しは上の空きの下、ブランチの器は下の空きの上）。
  var band: NSRect {
    switch content {
    case .header(let header) where header.section == .graph:
      NSRect(x: 0, y: Theme.Layout.editorScmGraphGap, width: bounds.width, height: Self.rowHeight)
    case .branch:
      NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Layout.editorScmBranch)
    default:
      bounds
    }
  }

  /// ボタンの枠（右から左へ並べた順に返す——左から並べ直して返す）。
  func buttonRects() -> [(Button, NSRect)] {
    let band = self.band
    switch content {
    case .header(let header):
      let tool = Theme.Layout.editorScmTool
      var right = bounds.width - (header.section == .graph ? Theme.Space.step : 12)
      if let count = header.count {
        right -= countWidth(count) + Theme.Space.tick
      }
      var rects: [(Button, NSRect)] = []
      for button in header.buttons.reversed() {
        rects.append(
          (button, NSRect(x: right - tool, y: band.midY - tool / 2, width: tool, height: tool)))
        right -= tool
      }
      return rects.reversed()
    case .file(let file):
      let size = Theme.Layout.editorScmRowButton
      var right = bounds.width - 12 - snap(file.badge.width, .up) - Theme.Space.note
      var rects: [(Button, NSRect)] = []
      for button in file.buttons.reversed() {
        rects.append(
          (button, NSRect(x: right - size, y: band.midY - size / 2, width: size, height: size)))
        right -= size + Theme.Space.hair
      }
      return rects.reversed()
    default:
      return []
    }
  }

  func countWidth(_ count: TextLine) -> CGFloat {
    max(Theme.Layout.editorSearchCountWidth, snap(count.width, .up) + 10)
  }

  override func control(at point: NSPoint) -> Int? {
    buttonRects().first { $0.1.contains(point) }.map { $0.0.control.rawValue }
  }

  override func help(at point: NSPoint) -> String? {
    buttonRects().first { $0.1.contains(point) }?.0.help
  }

  /// ポインタが乗っている部分が変わったときだけ描き直す（行の地・ボタンの地・さらに表示の字）。
  override func pointerDidChange(from old: NSPoint?) {
    let hovered = { (point: NSPoint?) -> (band: Bool, button: Int?) in
      guard let point else { return (false, nil) }
      return (self.band.contains(point), self.buttonRects().firstIndex { $0.1.contains(point) })
    }
    if hovered(old) != hovered(pointer) { needsDisplay = true }
  }

  var isHovered: Bool {
    guard let pointer else { return false }
    return band.contains(pointer)
  }

  // MARK: - 描画

  override func drawContent(_ colors: RowColors, in context: CGContext) {
    let scm = ScmRowColors.of(effectiveAppearance)
    switch content {
    case .header(let header): draw(header, colors, scm, in: context)
    case .file(let file): draw(file, colors, scm, in: context)
    case .branch(let branch): draw(branch, scm, in: context)
    case .commit(let commit): draw(commit, colors, scm, in: context)
    case .more(let text):
      text.draw(
        at: 42, top: snap((bounds.height - text.height) / 2),
        width: max(0, bounds.width - 42 - 12), isHovered ? colors.text : colors.muted, context)
    case nil: break
    }
  }
}
