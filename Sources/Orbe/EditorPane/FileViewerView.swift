import SwiftUI

/// 右ビューア（FileViewer）。文脈（ctx）で挙動が変わる:
/// ツリー閲覧（.tree）は非md=全文のみ（セグメント無し＋誘導文）・md=［ソース｜プレビュー］。
/// 変更レビュー（.changes）は ‹i/N› ナビ＋md=［ソース｜プレビュー｜diff］・非md=［ファイル｜diff］。
struct FileViewerView: View {
  @Bindable var model: EditorPaneModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(spacing: 0) {
      if let path = model.ui.selectedPath {
        header(path: path)
        if model.ctx == .changes, EditorPaneModel.isMarkdown(path), model.ui.viewMode == .preview {
          previewOverlayBand
        }
        body(path: path)
      } else {
        Text(l10n.string(.editorSelectFile))
          .font(Font.theme.paneRow)
          .foregroundStyle(Color.theme.textMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - ヘッダ

  private func header(path: String) -> some View {
    let change = model.statusByPath[path]
    let stat = model.diffStat(of: path)
    return HStack(spacing: 7) {
      titleLead(path: path)
      if let change {
        StatusBadgeView(badge: ChangeBadge.of(change))
        if stat.add > 0 || stat.del > 0 {
          AddDelText(add: stat.add, del: stat.del).layoutPriority(1)
        }
      }
      Spacer(minLength: 0)
      trailingControl(path: path)
    }
    .font(Font.theme.paneControl)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.horizontal, 12)
    .frame(height: 26)
    .paneRowClipped()
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.05)).frame(height: 1)
    }
  }

  /// ヘッダ左側: 変更は ‹i/N›＋パス（md のみアイコン）、ツリーはパンくず。
  @ViewBuilder private func titleLead(path: String) -> some View {
    if model.ctx == .changes {
      if let nav = model.viewerNav {
        HStack(spacing: 3) {
          Text(verbatim: "‹")
            .contentShape(Rectangle().inset(by: -4))
            .onTapGesture { model.selectAdjacentChange(-1) }
          Text(verbatim: "\(nav.index)/\(nav.count)")
          Text(verbatim: "›")
            .contentShape(Rectangle().inset(by: -4))
            .onTapGesture { model.selectAdjacentChange(1) }
        }
        .foregroundStyle(Color.theme.textSecondary)
        .layoutPriority(3)
      }
      // 見本準拠: 変更のアイコンは md のみ。
      if EditorPaneModel.isMarkdown(path) {
        FileIconView(name: MochaIcon.name(file: path))
      }
      fontResolver.text(path, base: Theme.Typography.paneControl)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
    } else {
      HStack(spacing: 7) {
        FileIconView(name: MochaIcon.name(file: path))
        fontResolver.text(
          String(EditorPaneModel.dirName(of: path).dropLast()), base: Theme.Typography.paneControl)
        Text(verbatim: "›")
        fontResolver.text(EditorPaneModel.fileName(of: path), base: Theme.Typography.paneControl)
          .foregroundStyle(Color.theme.textPrimary)
      }
      .lineLimit(1)
      .layoutPriority(2)
    }
  }

  /// ヘッダ右側: 表示セグメント、無い（ツリーの非md）なら変更操作の誘導文。
  @ViewBuilder private func trailingControl(path: String) -> some View {
    if let segs = segments(path: path) {
      PaneSegmented(items: segs, activeKey: activeKey, dense: true) { key in
        model.ui.viewMode = viewMode(for: key)
      }
      .layoutPriority(model.ctx == .changes ? 2 : 0)
    } else {
      (Text(l10n.string(.editorChangesHintLead))
        + Text(l10n.string(.editorGitToolWord)).foregroundColor(.theme.textSecondary)
        + Text(l10n.string(.editorChangesHintTail)))
        .font(Font.theme.paneSegment)
        .lineLimit(1)
    }
  }

  /// 表示セグメント。ツリー: 非md=nil（セグメント無し）・md=［ソース｜プレビュー］。
  /// 変更: md=［ソース｜プレビュー｜diff］・非md=［ファイル｜diff］。
  private func segments(path: String) -> [PaneSegmented.Item]? {
    let md = EditorPaneModel.isMarkdown(path)
    if model.ctx == .tree {
      return md
        ? [
          .init(key: "source", label: l10n.string(.editorSegSource)),
          .init(key: "preview", label: l10n.string(.editorSegPreview)),
        ]
        : nil
    }
    if md {
      return [
        .init(key: "source", label: l10n.string(.editorSegSource)),
        .init(key: "preview", label: l10n.string(.editorSegPreview)),
        .init(key: "diff", label: "diff"),
      ]
    }
    return [
      .init(key: "file", label: l10n.string(.editorSegFile)), .init(key: "diff", label: "diff"),
    ]
  }

  /// md × 変更 × プレビュー時の情報帯（プレビューに差分を重ねる旨の案内・見本 682–704）。
  private var previewOverlayBand: some View {
    HStack(spacing: 8) {
      Text(l10n.string(.editorPreviewOverlayTitle))
        .foregroundStyle(Color.theme.statusText)
      Text(l10n.string(.editorPreviewLegend))
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      (Text(l10n.string(.editorStageHintLead))
        + Text(verbatim: "diff").foregroundColor(.theme.textSecondary)
        + Text(l10n.string(.editorStageHintTail)))
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
    }
    .font(Font.theme.paneSegment)
    .padding(.horizontal, 12)
    .frame(height: 24)
    .paneRowClipped()
    .background(Color.theme.accentPrimary.opacity(0.08))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.accentPrimary.opacity(0.2)).frame(height: 1)
    }
  }

  private var activeKey: String {
    switch model.ui.viewMode {
    case .file: return "file"
    case .source: return "source"
    case .preview: return "preview"
    case .diff: return "diff"
    }
  }

  private func viewMode(for key: String) -> EditorViewMode {
    switch key {
    case "source": return .source
    case "preview": return .preview
    case "diff": return .diff
    default: return .file
    }
  }

  // MARK: - 本文

  @ViewBuilder private func body(path: String) -> some View {
    if let note = model.viewerNote(for: path) {
      viewerNote(note)
    } else {
      switch model.ui.viewMode {
      case .file, .source:
        if let lines = model.fileLines(for: path) {
          FileBodyView(lines: lines)
        } else {
          viewerNote(l10n.string(.editorNoteCannotShow))
        }
      case .preview:
        MarkdownPreview(markdown: model.cachedContent(path) ?? "")
      case .diff:
        DiffHunksView(model: model, path: path)
      }
    }
  }

  private func viewerNote(_ note: String) -> some View {
    Text(note)
      .font(Font.theme.paneRow)
      .foregroundStyle(Color.theme.textMuted)
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// ファイル全文（FileBody）。行番号＋変更行ガターマーク（add=緑 / mod=accent）。
struct FileBodyView: View {
  let lines: [PaneFileLine]
  /// コード本文行の絵文字も設定フォントで描く。絵文字を含まない行（大半）は resolver 内の
  /// 早期打ち切りで素の Text のまま（AttributedString を組まない）。
  @Environment(\.chromeFontResolver) private var fontResolver

  /// 見本の lineHeight 1.7 × 10.5px。
  static let lineHeight: CGFloat = 10.5 * Theme.Typography.linePane

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(lines) { line in
          row(line)
        }
      }
      .padding(.vertical, 5)
    }
  }

  private func row(_ line: PaneFileLine) -> some View {
    HStack(spacing: 0) {
      Text(verbatim: "\(line.n)")
        .foregroundStyle(
          line.mark != nil
            ? Color.theme.diffAdded.opacity(0.65) : Color.theme.textMuted.opacity(0.55)
        )
        .frame(width: 30, alignment: .trailing)
        .padding(.trailing, 8)
      Rectangle()
        .fill(gutterColor(line.mark))
        .frame(width: 3)
      fontResolver.text(line.text.isEmpty ? " " : line.text, base: Theme.Typography.paneRow)
        .foregroundStyle(line.mark != nil ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .padding(.leading, 8)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .font(Font.theme.paneRow)
    .frame(height: Self.lineHeight)
    .paneRowClipped()
  }

  private func gutterColor(_ mark: PaneFileLine.Mark?) -> Color {
    switch mark {
    case .add: return .theme.diffAdded
    case .mod: return .theme.accentPrimary
    case nil: return .clear
    }
  }
}

/// md の通常プレビュー（MarkdownView に EditorPane スタイルを注入）。
struct MarkdownPreview: View {
  let markdown: String

  var body: some View {
    MarkdownView(markdown: markdown)
      .environment(\.markdownStyle, .editorPane)
  }
}

extension MarkdownStyle {
  /// EditorPane の md プレビュー実寸（MdPreviewBody）。
  static let editorPane = MarkdownStyle(
    titleFont: Font.theme.proseTitle,
    headingFont: Font.theme.proseHeading,
    headingUnderline: true,
    bodyFont: Font.theme.proseBody,
    bodyLineSpacing: 3.5,  // line-height 1.7 相当
    bulletColor: Color.theme.accentPrimary,
    inlineCodeFont: Font.theme.paneRow,
    inlineCodeBackground: Color.theme.tabRowBg,
    codeBlockFont: Font.theme.paneRow,
    codeBlockColor: Color.theme.promptGreen,
    codeBlockBackground: Color.theme.tabRowBg,
    codeBlockBordered: true,
    codeBlockRadius: 6,
    blockSpacing: 8,
    contentPadding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
}
