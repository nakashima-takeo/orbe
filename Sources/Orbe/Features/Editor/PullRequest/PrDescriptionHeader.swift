import AppKit

/// PR のパネルの列の頭——「説明」の見出し（押して畳める。↑↓ では選ばない）と、説明の本文の先頭 3 行（書かれた字のまま。越える分は末尾を省く。
/// padding 0 14 8 20・11.5・行の高さ 1.6）。説明が空なら高さ 0。行と一緒に送る（→ `RowListHeader`）。
final class PrDescriptionHeader: NSView, RowListHeader {
  /// 見出しを押した（開閉）。
  var onToggle: () -> Void = {}
  private let body = NSTextField(wrappingLabelWithString: "")
  private var text = ""
  private var isOpen = true
  private var titleText = ""
  private var title = TextLine("", Theme.Typography.editorScmSection)
  private var hovering = false
  private var hoverArea: NSTrackingArea?

  private static let bodyInsets = NSEdgeInsets(top: 0, left: 20, bottom: 8, right: 14)

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.font = Theme.Typography.editorPrDescription
    body.textColor = Theme.Color.editorProse
    body.maximumNumberOfLines = Theme.Layout.editorPrDescriptionLines
    body.lineBreakMode = .byTruncatingTail
    body.cell?.truncatesLastVisibleLine = true
    body.isSelectable = false
    addSubview(body)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  /// 説明 `text`（書かれた字のまま）と開閉と見出しの文言を写す。変わったら true（持ち主が列に高さを測り直させる）。
  @discardableResult
  func show(_ text: String, isOpen: Bool, title: String) -> Bool {
    guard text != self.text || isOpen != self.isOpen || title != titleText else {
      return false
    }
    self.text = text
    self.isOpen = isOpen
    titleText = title
    self.title = TextLine(title, Theme.Typography.editorScmSection)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = Theme.Typography.editorPrDescription.extraLeading(
      lineHeight: Theme.Typography.editorPrDescriptionLineHeight)
    body.attributedStringValue = NSAttributedString(
      string: text,
      attributes: [
        .font: Theme.Typography.editorPrDescription, .foregroundColor: Theme.Color.editorProse,
        .paragraphStyle: paragraph,
      ])
    body.isHidden = !isOpen || text.isEmpty
    needsLayout = true
    needsDisplay = true
    return true
  }

  func height(fitting width: CGFloat) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    return Theme.Layout.editorScmRow + bodyHeight(fitting: width)
  }

  private func bodyHeight(fitting width: CGFloat) -> CGFloat {
    guard isOpen else { return 0 }
    let insets = Self.bodyInsets
    let inner = max(0, width - insets.left - insets.right)
    let size = body.cell?.cellSize(
      forBounds: NSRect(x: 0, y: 0, width: inner, height: .greatestFiniteMagnitude))
    let font = Theme.Typography.editorPrDescription
    let limit =
      font.pointSize * Theme.Typography.editorPrDescriptionLineHeight
      * CGFloat(Theme.Layout.editorPrDescriptionLines)
    return min(size?.height ?? 0, limit).rounded(.up) + insets.top + insets.bottom
  }

  override func layout() {
    super.layout()
    let insets = Self.bodyInsets
    let row = Theme.Layout.editorScmRow
    body.frame = NSRect(
      x: insets.left, y: row + insets.top, width: max(0, bounds.width - insets.left - insets.right),
      height: max(0, bodyHeight(fitting: bounds.width) - insets.top - insets.bottom))
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
    let colors = RowColors.of(effectiveAppearance)
    let scm = ScmRowColors.of(effectiveAppearance)
    let row = NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Layout.editorScmRow)
    if hovering {
      context.setFillColor(scm.headerHover)
      context.fill(row)
    }
    let chevron = Theme.Layout.editorChevron
    (isOpen ? RowGlyphShape.chevronOpen : .chevron).draw(
      in: NSRect(x: Theme.Space.tick, y: row.midY - chevron / 2, width: chevron, height: chevron),
      scm.icon, in: context)
    let x = Theme.Space.tick + chevron
    title.draw(
      at: x, top: ((row.height - title.height) / 2).rounded(), width: bounds.width - x - 12,
      colors.text, context)
  }

  // MARK: - 押下と hover

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard point.y < Theme.Layout.editorScmRow else { return super.mouseDown(with: event) }
    onToggle()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Layout.editorScmRow),
      options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    needsDisplay = true
  }
}
