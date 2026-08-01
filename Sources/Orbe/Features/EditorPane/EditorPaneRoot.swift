import SwiftUI

/// EditorPane の SwiftUI ルート（EditorPane v4）。左端スプリッタ視覚＋
/// メインカラム（ツール別ヘッダー＋本体）＋右端 ToolRail を合成する。空状態も持つ。
struct EditorPaneRoot: View {
  @Bindable var model: EditorPaneModel
  /// 背景透過/ブラー（既定は不透明＝preview/fixture は現行描画）。WindowController が実ホルダーを渡す。
  var translucency = ChromeTranslucency()
  /// フォント割り当て（別 NSHostingView root のため AppShell と同じ実ホルダーを注入する。既定は素の割り当て）。
  var fontResolver = ChromeFontResolver()
  /// 現在言語（別 NSHostingView root のため AppShell と同じ実ホルダーを注入する。既定は OS 追従）。
  var localization = LocalizationStore(language: .systemDefault)

  var body: some View {
    content
      .background(Color.theme.paneWash)
      // 元来 BackgroundGlow の不透明 bgBase が担っていたペインの地を、この面が自前で持つ。
      // 不透明時は不透明 bgBase・透過時は端末と同濃度へ薄める（BackgroundGlow が透過時 clear のため）。
      .background(translucency.baseFill)
      .environment(\.chromeTranslucency, translucency)
      .environment(\.chromeFontResolver, fontResolver)
      .environment(\.localization, localization)
  }

  /// スプリッタ視覚（幅 5・中央グリップ 2×34。ドラッグは facade の PaneResizeHandle が受ける）。
  private var splitter: some View {
    Rectangle()
      .fill(Color.theme.surfaceInk.opacity(0.05))
      .frame(width: 5)
      .overlay(alignment: .leading) {
        Rectangle().fill(Color.theme.surfaceInk.opacity(0.08)).frame(width: 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.theme.surfaceInk.opacity(0.16))
          .frame(width: 2, height: 34)
      }
  }

  @ViewBuilder private var content: some View {
    if let empty = model.empty {
      // 空状態（git 外・cwd 不明）: facade ごと隠れる（AppShell 側）が、念のため文言を出す。
      Text(empty)
        .font(Font.theme.paneRow)
        .foregroundStyle(Color.theme.textMuted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.phrase)
    } else if model.ui.paneOpen {
      // 本体を開いている: スプリッタ＋メインカラム＋常駐レール。
      HStack(spacing: 0) {
        splitter
        mainColumn
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        toolRail
      }
    } else {
      // 本体を閉じている: 常駐レール(32px)のみ。
      toolRail
    }
  }

  private var toolRail: some View {
    ToolRailView(
      tool: model.ui.tool,
      paneOpen: model.ui.paneOpen,
      hasChanges: !model.changedFiles.isEmpty,
      devServerRunning: model.devServerURL != nil,
      onSelect: { model.selectTool($0) })
  }

  /// ツールレールの左のメインカラム（ツール別ヘッダー＋本体）。
  @ViewBuilder private var mainColumn: some View {
    VStack(spacing: 0) {
      switch model.ui.tool {
      case .tree:
        TreeHeader()
        HStack(spacing: 0) {
          TreeRailView(model: model)
            .frame(width: listWidth)
            .overlay(alignment: .trailing) { listBorder }
          FileViewerView(model: model)
        }
        .frame(maxHeight: .infinity)
      case .git:
        GitHeader(model: model)
        HStack(spacing: 0) {
          gitList
            .frame(width: listWidth)
            .overlay(alignment: .trailing) { listBorder }
          if model.ui.gitTab == .changes {
            FileViewerView(model: model)
          } else {
            CommitDetailView(model: model)
          }
        }
        .frame(maxHeight: .infinity)
        if model.ui.gitTab == .changes {
          if let banner = model.banner {
            PaneBannerStrip(banner: banner) { model.banner = nil }
          }
          CommitBarView(model: model)
        }
      case .browser:
        BrowserHeader(model: model)
        BrowserBody(model: model)
        BrowserFooter(model: model)
      }
    }
  }

  /// git リストカラム（変更/履歴サブタブ切替ヘッダー＋各サブタブの中身）。
  private var gitList: some View {
    VStack(spacing: 0) {
      gitListHeader
      switch model.ui.gitTab {
      case .changes: ChangesRailView(model: model)
      case .history: HistoryRailView(model: model)
      }
    }
    .font(Font.theme.paneRow)
  }

  /// 変更 N / 履歴 の Segmented ＋（変更時のみ）並び順（無配線）。
  private var gitListHeader: some View {
    HStack(spacing: 4) {
      PaneSegmented(
        items: [
          .init(
            key: "changes", label: localization.format(.gitChangesTab, model.changedFiles.count)),
          .init(key: "history", label: localization.string(.gitHistory)),
        ],
        activeKey: model.ui.gitTab == .changes ? "changes" : "history"
      ) { key in
        model.selectGitTab(key == "history" ? .history : .changes)
      }
      Spacer(minLength: 0)
      if model.ui.gitTab == .changes {
        Text(localization.string(.gitSortNewest))  // 描画のみ・無配線（ソート切替は後続 task）
          .font(Font.theme.paneSegment)
          .foregroundStyle(Color.theme.textSecondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .paneRowClipped()
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.05)).frame(height: 1)
    }
  }

  private var listBorder: some View {
    Rectangle().fill(Color.theme.surfaceInk.opacity(0.06)).frame(width: 1)
  }

  /// 履歴サブタブのみ 240、他は 196。
  private var listWidth: CGFloat {
    model.ui.tool == .git && model.ui.gitTab == .history ? 240 : 196
  }
}
