import AppKit
import SwiftUI

/// エクスプローラーの下段「アウトライン」の区画: 見出し（見本 SectionHead）と、開いていれば中身（行の列か文言）。状態は
/// `EditorOutline` だけを読み、開閉は `EditorSidebarState`（アプリ全体で 1 つ）。
struct OutlineSectionView: View {
  let outline: EditorOutline
  let list: OutlineListView
  let sidebar: EditorSidebarState

  var body: some View {
    VStack(spacing: 0) {
      OutlineSectionHeader(outline: outline, sidebar: sidebar)
      if sidebar.isOutlineOpen { OutlineSectionBody(outline: outline, list: list) }
    }
  }
}

/// 見出し 22（上に hairline 1）: シェブロン・題（11 bold）。押すと開閉する。ホバー中だけ地が付き、開いていれば右端に
/// 「すべて折りたたむ／すべて展開」の切り替えが 1 つ出る。
private struct OutlineSectionHeader: View {
  let outline: EditorOutline
  let sidebar: EditorSidebarState
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  // 見本 SectionHead の値。
  private static let hoverFillAlpha = 0.04
  private static let hairlineAlpha = 0.07

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: 0) {
      TreeChevron(open: sidebar.isOutlineOpen)
      Text(l10n.string(.editorOutlineTitle))
        .font(Font.theme.editorSectionTitle)
        .foregroundStyle(Color.theme.editorText)
        .lineLimit(1)
      Spacer(minLength: 0)
      if hovering, sidebar.isOutlineOpen, outline.status == .ready {
        EditorIconButton(
          glyph: outline.isAllCollapsed ? EditorGlyphs.expandAll : EditorGlyphs.collapseAll,
          help: l10n.string(outline.isAllCollapsed ? .editorExpandAll : .editorCollapseAll),
          action: outline.toggleCollapseAll)
      }
    }
    .padding(.leading, Theme.Layout.editorOutlineInset)
    .padding(.trailing, Theme.Space.step)
    .frame(height: Theme.Layout.editorSectionHeader)
    .background(hovering ? ink.fill(Self.hoverFillAlpha) : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture(perform: sidebar.toggleOutline)
    .padding(.top, Theme.Stroke.hairline)
    .overlay(alignment: .top) {
      Rectangle().fill(ink.hairline(Self.hairlineAlpha)).frame(height: Theme.Stroke.hairline)
    }
  }
}

/// 中身: シンボルがあれば行の列（絞り込みの欄つき）、無ければ VS Code の文言（取り出し中の文言は、すぐ届けば出さない）。
private struct OutlineSectionBody: View {
  let outline: EditorOutline
  let list: OutlineListView
  @Environment(\.localization) private var l10n

  var body: some View {
    switch outline.status {
    case .ready:
      OutlineListHost(
        list: list, rowsVersion: outline.rowsVersion, selection: outline.selection,
        filterShown: outline.isFilterShown, filterText: outline.filterText
      )
      .padding(.top, Theme.Layout.editorOutlineListTop)
    case .loading:
      if outline.showsLoading {
        message(l10n.format(.editorOutlineLoading, outline.documentName))
      } else {
        Spacer(minLength: 0)
      }
    case .empty:
      message(l10n.format(.editorOutlineEmpty, outline.documentName))
    case .unavailable:
      message(l10n.string(.editorOutlineUnavailable))
    }
  }

  /// 文言（11 tertiary、padding 10 12）。
  private func message(_ text: String) -> some View {
    Text(text)
      .font(Font.theme.editorSearchNote)
      .foregroundStyle(Color.theme.editorTertiary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
  }
}

/// 区画の境（アウトラインの見出しの上の hairline）に置く縦のドラッグの当たり。掴んだときのアウトラインの区画の高さを起点に、
/// ポインタの移動ぶんだけ高さを求める（横幅の `SidebarResizeHandle` と同じ作法）。
struct SectionResizeHandle: NSViewRepresentable {
  /// 掴んだときの高さを返す。
  let grab: () -> CGFloat
  /// ポインタが求める高さ。
  let drag: (CGFloat) -> Void
  let release: () -> Void

  func makeNSView(context: Context) -> SectionResizeHandleView { SectionResizeHandleView() }

  func updateNSView(_ view: SectionResizeHandleView, context: Context) {
    view.grab = grab
    view.drag = drag
    view.release = release
  }
}

final class SectionResizeHandleView: NSView {
  var grab: () -> CGFloat = { 0 }
  var drag: (CGFloat) -> Void = { _ in }
  var release: () -> Void = {}
  private var origin: (y: CGFloat, height: CGFloat)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.resizeUpDown.set()
  }

  override func mouseDown(with event: NSEvent) {
    origin = (event.locationInWindow.y, grab())
  }

  override func mouseDragged(with event: NSEvent) {
    guard let origin else { return }
    // 窓の座標は上向き。上へ引くとアウトラインが高くなる。
    drag(origin.height + event.locationInWindow.y - origin.y)
  }

  override func mouseUp(with event: NSEvent) {
    guard origin != nil else { return }
    origin = nil
    release()
  }
}
