import AppKit

/// グラフの列の 1 行（先頭のブランチの行・コミット・さらに表示）を描く。コミットと「さらに表示」の寸法と色は見本 ScmPanel
/// の値。枠も地も無いブランチの行 22 は見本に無い（人の決定 H20）。印は点の列、名前と題は点の列の右の同じ左端から並べる。
/// 押せるのは「さらに表示」だけで、行の中のボタンは持たない。
final class ScmGraphRowView: ListRowView {
  enum Content {
    case branch(Branch)
    case commit(Commit)
    case more(TextLine)
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

  /// 点の列の左端と、名前・題の左端（点の列の右に gap 6）。
  private static let column: CGFloat = 20
  private static let text = column + Theme.Layout.editorScmDotColumn + Theme.Space.note

  /// 最初の行を描く前に 1 度だけ要る準備（色の解決・字体の初回の字組み）。
  static func prepare(for appearance: NSAppearance) {
    _ = RowColors.of(appearance)
    _ = ScmRowColors.of(appearance)
    TextLine.prepare([
      Theme.Typography.editorScmCommit, Theme.Typography.editorScmRef,
      Theme.Typography.editorScmBranch, Theme.Typography.editorScmMore,
    ])
  }

  func show(_ item: ScmGraphLayout.Item, language: Language, emoji: NSFont?) {
    let key = Self.key(item, language) + (emoji.map { "\u{0}\($0.fontName)" } ?? "")
    guard key != self.key else { return }
    self.key = key
    content = Self.content(item, language, emoji)
    setAccessibilityLabel(Self.label(item, language))
    needsDisplay = true
  }

  /// 「さらに表示」の字だけが、ポインタの出入りで描き直す。
  override func pointerDidChange(from old: NSPoint?) {
    if case .more = content, (old == nil) != (pointer == nil) { needsDisplay = true }
  }

  // MARK: - 中身

  private static func key(_ item: ScmGraphLayout.Item, _ language: Language) -> String {
    switch item {
    case .branch(let branch): "b\(branch.label)\u{0}\(branch.divergence?.arrows ?? "")"
    case .commit(let commit, let isFirst, let isLast):
      "c\(commit.oid)\(commit.isPushed)\(isFirst)\(isLast)\(commit.localBranches)\(commit.remoteBranches)"
    case .more: "m\(language)"
    }
  }

  private static func label(_ item: ScmGraphLayout.Item, _ language: Language) -> String {
    switch item {
    case .branch(let branch): branch.label
    case .commit(let commit, _, _): commit.subject
    case .more: L10n.string(.editorScmShowMore, language)
    }
  }

  private static func content(
    _ item: ScmGraphLayout.Item, _ language: Language, _ emoji: NSFont?
  ) -> Content {
    switch item {
    case .branch(let branch):
      .branch(
        Branch(
          name: TextLine(
            branch.label, Theme.Typography.editorScmBranch, glyphs: .chrome(emoji: emoji)),
          divergence: branch.divergence.map(\.arrows).flatMap {
            $0.isEmpty ? nil : TextLine($0, Theme.Typography.editorScmBranch)
          }))
    case .commit(let commit, let isFirst, let isLast):
      .commit(
        Commit(
          subject: TextLine(
            commit.subject, Theme.Typography.editorScmCommit, glyphs: .chrome(emoji: emoji)),
          isPushed: commit.isPushed, isFirst: isFirst, isLast: isLast,
          refs: commit.localBranches.map { (TextLine($0, Theme.Typography.editorScmRef), true) }
            + commit.remoteBranches.map { (TextLine($0, Theme.Typography.editorScmRef), false) }))
    case .more:
      .more(TextLine(L10n.string(.editorScmShowMore, language), Theme.Typography.editorScmMore))
    }
  }

  // MARK: - 描画

  override func drawContent(_ colors: RowColors, in context: CGContext) {
    let scm = ScmRowColors.of(effectiveAppearance)
    switch content {
    case .branch(let branch): draw(branch, colors, scm, in: context)
    case .commit(let commit): draw(commit, colors, scm, in: context)
    case .more(let text):
      text.draw(
        at: Self.text, top: top(text), width: max(0, bounds.width - Self.text - 12),
        pointer != nil ? colors.text : colors.muted, context)
    case nil: break
    }
  }

  /// ブランチの行 22（padding 0 12 0 20・gap 6。枠も地も当たりも持たない）: ブランチの印 9（accentBright）を点の列の中央に、
  /// 名前と先行/遅れ（mono 11。数は tertiary）を題の列に。名前を優先し、先行/遅れは残りの幅で末尾から省く。
  private func draw(
    _ branch: Branch, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext
  ) {
    let glyph: CGFloat = 9
    let center = Self.column + Theme.Layout.editorScmDotColumn / 2
    ScmGlyphShape.branch.draw(
      in: NSRect(x: center - glyph / 2, y: bounds.midY - glyph / 2, width: glyph, height: glyph),
      scm.accent, in: context)
    let gap = Theme.Space.note
    var x = Self.text
    let limit = bounds.width - 12
    let nameWidth = min(snap(branch.name.width, .up), max(0, limit - x))
    branch.name.draw(at: x, top: top(branch.name), width: nameWidth, colors.text, context)
    x += nameWidth + gap
    if let divergence = branch.divergence {
      divergence.draw(
        at: x, top: top(divergence), width: max(0, limit - x), colors.tertiary, context)
    }
  }

  /// コミット 22（padding 0 12 0 20・gap 6）: 点の列 16（未 push は塗り accentBright と地の輪、push 済みは中抜き tertiary）と
  /// 縦の線・題 12（push 済みは muted）・右端に ref の札（local は accent、remote は無彩）。札が入らなければ末尾から省く。題の
  /// 右は伸びる余白の両側の gap を空ける（札との間 12、札が無ければ右端の padding との間 6）。
  private func draw(
    _ commit: Commit, _ colors: RowColors, _ scm: ScmRowColors, in context: CGContext
  ) {
    let column = Theme.Layout.editorScmDotColumn
    let lineX: CGFloat = 27
    let top = commit.isFirst ? Theme.Space.step : 0
    let bottom = commit.isLast ? bounds.height - Theme.Space.step : bounds.height
    if bottom > top {
      context.setFillColor(scm.graphLine)
      context.fill(NSRect(x: lineX, y: top, width: Theme.Stroke.hairline, height: bottom - top))
    }
    let dot = Theme.Layout.editorScmDot
    let center = NSPoint(x: Self.column + column / 2, y: bounds.height / 2)
    let dotRect = NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)
    if commit.isPushed {
      context.setFillColor(scm.ground)
      context.fillEllipse(in: dotRect)
      context.setStrokeColor(colors.tertiary)
      context.setLineWidth(1.5)
      context.strokeEllipse(in: dotRect.insetBy(dx: 0.75, dy: 0.75))
    } else {
      context.setFillColor(scm.ground)
      context.fillEllipse(in: dotRect.insetBy(dx: -2, dy: -2))
      context.setFillColor(scm.accent)
      context.fillEllipse(in: dotRect)
    }
    let gap = Theme.Space.note
    let x = Self.text
    let limit = bounds.width - 12
    var refs = commit.refs
    var widths = refs.map { refWidth($0.label) }
    let minimumSubject: CGFloat = 48
    func subjectRight(_ widths: [CGFloat]) -> CGFloat {
      widths.isEmpty
        ? limit - gap
        : limit - widths.reduce(0, +) - CGFloat(widths.count - 1) * Theme.Space.tick - gap * 2
    }
    while !refs.isEmpty, subjectRight(widths) - x < minimumSubject {
      refs.removeLast()
      widths.removeLast()
    }
    var right = limit
    for (ref, width) in zip(refs, widths).reversed() {
      drawRef(
        ref,
        in: NSRect(
          x: right - width, y: snap((bounds.height - Theme.Layout.editorScmRef) / 2), width: width,
          height: Theme.Layout.editorScmRef), colors, scm, in: context)
      right -= width + Theme.Space.tick
    }
    commit.subject.draw(
      at: x, top: self.top(commit.subject), width: max(0, subjectRight(widths) - x),
      commit.isPushed ? colors.muted : colors.text, context)
  }

  private func refWidth(_ label: TextLine) -> CGFloat {
    5 + 8 + 3 + snap(label.width, .up) + 5
  }

  /// ref の札 15（radius 3・padding 0 5・枠 1px）: ブランチの印 8 と名前（mono 9）。
  private func drawRef(
    _ ref: (label: TextLine, isLocal: Bool), in rect: NSRect, _ colors: RowColors,
    _ scm: ScmRowColors, in context: CGContext
  ) {
    let (label, isLocal) = ref
    let color = isLocal ? scm.accent : colors.muted
    fill(
      rect, radius: Theme.Radius.xs, isLocal ? scm.localRefGround : scm.remoteRefGround, in: context
    )
    context.setStrokeColor(isLocal ? scm.localRefBorder : scm.remoteRefBorder)
    context.setLineWidth(Theme.Stroke.hairline)
    context.addPath(
      CGPath(
        roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Theme.Radius.xs - 0.5,
        cornerHeight: Theme.Radius.xs - 0.5, transform: nil))
    context.strokePath()
    let glyph: CGFloat = 8
    ScmGlyphShape.branch.draw(
      in: NSRect(x: rect.minX + 5, y: rect.midY - glyph / 2, width: glyph, height: glyph),
      color, in: context)
    label.draw(
      at: rect.minX + 5 + glyph + 3, top: snap(rect.midY - label.height / 2), color, context)
  }
}
