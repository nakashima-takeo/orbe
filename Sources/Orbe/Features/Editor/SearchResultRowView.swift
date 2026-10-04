import AppKit
import OrbeEditorCore

/// 結果の 1 行（見出しか一致）の中身を描く。文字は CoreText の行で持ち、中身が変わったときだけ組み直して描き直す。
/// VoiceOver には中身の文字列を渡す。
final class SearchResultRowView: ListRowView {

  /// 描いている中身の同一性（同じなら組み直さない）。
  private enum Key: Equatable {
    case file(ProjectSearch.RowID, count: Int, isCollapsed: Bool)
    case match(ProjectSearch.RowID, SearchPreview)
  }

  private enum Content {
    case file(FileContent)
    case match(MatchContent)
  }

  private struct FileContent {
    let isCollapsed: Bool
    let chip: FileChip
    let chipText: TextLine
    let name: TextLine
    let directory: TextLine
    let count: TextLine
  }

  private struct MatchContent {
    /// 前（行末の空白を除く）と、その空白の幅。行末の空白は省略の計算で幅に入らないので、間として別に取っておく。
    let before: TextLine
    let beforeGap: CGFloat
    let match: TextLine
    let after: TextLine
  }

  private var key: Key?
  private var emoji: NSFont?
  private var content: Content?

  private static let hitRadius: CGFloat = 2
  private static let countPadding: CGFloat = 5
  private static let matchEllipsisWidth = TextLine.ellipsisWidth(
    Theme.Typography.editorSearchMatch)

  /// 最初の行を描く前に 1 度だけ要る準備——字体の読み込みと初回の字組み（種別チップの太字の等幅は 1 つで 1ms を超える）・
  /// 色の解決・線の形。空の列へ最初の結果が入る更新にこれらの初回の費用が重ならないよう、結果の列が出たときに済ませる。
  static func prepare(for appearance: NSAppearance) {
    _ = RowColors.of(appearance)
    _ = SearchRowColors.of(appearance)
    _ = chevron(size: Theme.Layout.editorSearchChevron)
    let chipFonts = Set(
      ["S", "{}", "TS"].map { FileChip(glyph: $0, hue: nil).fontSize(for: Theme.Layout.editorChip) }
    ).map { Theme.Typography.editorChip(size: $0) }
    TextLine.prepare(
      [
        Theme.Typography.editorSearchFile, Theme.Typography.editorSearchDirectory,
        Theme.Typography.editorSearchMatch, Theme.Typography.editorSearchCount,
      ] + chipFonts)
  }

  func show(_ row: ProjectSearch.Row, emoji: NSFont?) {
    let key: Key
    switch row {
    case .file(let file, let isCollapsed):
      key = .file(row.id, count: file.count, isCollapsed: isCollapsed)
    case .match(_, _, let match):
      key = .match(row.id, match.preview)
    }
    guard key != self.key || emoji !== self.emoji else { return }
    self.key = key
    self.emoji = emoji
    switch row {
    case .file(let file, let isCollapsed):
      let name = (file.path as NSString).lastPathComponent
      let directory = (file.path as NSString).deletingLastPathComponent
      let chip = Self.chip(named: name)
      content = .file(
        FileContent(
          isCollapsed: isCollapsed, chip: chip,
          chipText: TextLine(
            chip.glyph,
            Theme.Typography.editorChip(size: chip.fontSize(for: Theme.Layout.editorChip))),
          name: TextLine(name, Theme.Typography.editorSearchFile, glyphs: .chrome(emoji: emoji)),
          directory: TextLine(
            directory, Theme.Typography.editorSearchDirectory, glyphs: .chrome(emoji: emoji),
            truncating: .start),
          count: TextLine(file.count.formatted(), Theme.Typography.editorSearchCount)))
      setAccessibilityLabel(
        [name, directory, "\(file.count)"].filter { !$0.isEmpty }.joined(separator: ", "))
    case .match(_, _, let match):
      let font = Theme.Typography.editorSearchMatch
      let preview = match.preview
      let bodyEnd =
        preview.before.lastIndex { $0 != " " }.map { preview.before.index(after: $0) }
        ?? preview.before.startIndex
      let beforeBody = String(preview.before[..<bodyEnd])
      let beforeSpaces = String(preview.before[bodyEnd...])
      content = .match(
        MatchContent(
          before: TextLine(beforeBody, font, truncating: .start),
          beforeGap: TextLine(beforeSpaces, font).width,
          match: TextLine(preview.match, font),
          after: TextLine(preview.after, font)))
      setAccessibilityLabel(preview.before + preview.match + preview.after)
    }
    needsDisplay = true
  }

  /// 種別チップ（名前ごとに 1 度だけ決める——結果の見出しは同じ種別の名前が並び、行を入れ替えるたびに決め直さない）。
  private static var chips: [String: FileChip] = [:]

  private static func chip(named name: String) -> FileChip {
    if let chip = chips[name] { return chip }
    let chip = FileChip.resolve(URL(fileURLWithPath: name))
    chips[name] = chip
    return chip
  }

  override func drawContent(_ colors: RowColors, in context: CGContext) {
    let search = SearchRowColors.of(effectiveAppearance)
    switch content {
    case .file(let file): draw(file, colors, search, in: context)
    case .match(let match): draw(match, colors, search, in: context)
    case nil: break
    }
  }

  /// 見出し: シェブロン（畳むと右向き）・種別チップ 14・ファイル名 12・ディレクトリ 10.5 tertiary・右端の件数。間は 6。
  /// 列が狭いときはファイル名を先に取り、ディレクトリは頭を省略して残りに詰める。
  private func draw(
    _ file: FileContent, _ colors: RowColors, _ search: SearchRowColors, in context: CGContext
  ) {
    let gap = Theme.Space.note
    var x = Theme.Space.beat
    drawChevron(
      at: x, size: Theme.Layout.editorSearchChevron, open: !file.isCollapsed, colors.muted,
      in: context)
    x += Theme.Layout.editorSearchChevron + gap
    drawChip(file.chipText, file.chip.tint, at: x, colors, in: context)
    x += Theme.Layout.editorChip + gap

    let badgeWidth = max(
      Theme.Layout.editorSearchCountWidth, snap(file.count.width, .up) + Self.countPadding * 2)
    let badgeHeight = max(Theme.Layout.editorSearchCountHeight, snap(file.count.height))
    let badge = NSRect(
      x: bounds.width - Theme.Space.beat - badgeWidth, y: snap((bounds.height - badgeHeight) / 2),
      width: badgeWidth, height: badgeHeight)
    fill(badge, radius: badgeHeight / 2, search.countFill, in: context)
    file.count.draw(
      at: snap(badge.midX - file.count.width / 2), top: snap(badge.midY - file.count.height / 2),
      colors.secondary, context)

    // 名前とディレクトリの間、ディレクトリと件数の間（伸びる余白の両側）にも間を置く。
    let limit = badge.minX - gap * 2
    let nameWidth = min(snap(file.name.width, .up), max(0, limit - x))
    file.name.draw(
      at: x, top: top(file.name), width: nameWidth, colors.primary, context)
    x += nameWidth + gap
    let directoryWidth = min(snap(file.directory.width, .up), limit - x)
    file.directory.draw(
      at: x, top: top(file.directory), width: directoryWidth,
      colors.tertiary, context)
  }

  /// 一致の行（左 40・mono 11）: 前 tertiary、ヒット（地 tint(modified, .30) 角 2・文字 primary）、後ろ muted。
  /// 列が狭いときは、前と後ろに省略記号 1 つぶんを残して、後ろ → 前（頭を省略）→ ヒットの順に詰める。
  private func draw(
    _ match: MatchContent, _ colors: RowColors, _ search: SearchRowColors, in context: CGContext
  ) {
    let ellipsis = Self.matchEllipsisWidth
    let x = Theme.Layout.editorSearchMatchIndent
    let room = max(0, bounds.width - Theme.Space.beat - x)
    let before = snap(match.before.width + match.beforeGap, .up)
    let after = snap(match.after.width, .up)
    let afterMin = min(after, ellipsis)
    let matchWidth = min(
      snap(match.match.width, .up), max(0, room - min(before, ellipsis) - afterMin))
    let beforeWidth = min(before, max(0, room - matchWidth - afterMin))

    let top = top(match.match)
    var beforeUsed = beforeWidth
    if let body = match.before.fitted(beforeWidth - match.beforeGap) {
      match.before.draw(body, at: x, top: top, colors.tertiary, context)
      // 頭を省いた前は省いた後の幅だけを取り、余りは後ろへ回す（SwiftUI の Text と同じ）。
      beforeUsed = snap(TextLine.width(of: body) + match.beforeGap, .up)
    }
    let afterWidth = min(after, room - beforeUsed - matchWidth)
    let hitLeft = x + beforeUsed
    let hitRight = hitLeft + matchWidth
    let hit = NSRect(
      x: hitLeft, y: top, width: hitRight - hitLeft, height: snap(match.match.height))
    fill(hit, radius: Self.hitRadius, search.hit, in: context)
    match.match.draw(
      at: hitLeft, top: top, width: matchWidth, colors.primary, context)
    match.after.draw(
      at: hitRight, top: top, width: afterWidth, colors.muted, context)
  }
}
