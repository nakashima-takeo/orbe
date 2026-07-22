import AppKit
import SwiftUI

/// SwiftUI ルート（`window.contentView` の `NSHostingView`）が配置する受け渡し用の薄い橋。
/// 状態の所有は WindowController/AgentLauncher のまま。ここは「何をどこに置くか」だけを運ぶ。
///
/// ドメイン状態（`workspaces`/`activeWorkspace` 等）は意図的にここへ持ち上げない＝WindowController を
/// 命令的コーディネータとして残す。端末ペインツリーは AppKit を命令的に reparent するしかなく
/// （NSView 同一性依存の keep-alive・scrollback は declarative で表現不能＝NSViewRepresentable＋
/// Coordinator 境界そのもの）、chrome は `refreshChrome()` の Snapshot 投影で既に reactive。
/// 生ドメインを View に晒すと SwiftUI が AppKit 型（`TerminalController` 等）へ結合し分離が悪化する。
@Observable final class AppShellModel {
  /// 前面 overlay の種別。`AppShell` が `.overlay` で対応する SwiftUI を compose する。
  enum Overlay {
    case none, languageSelect, workspacePalette, workspaceCreate, agentPalette, dispatchPalette,
      settingsPalette, onboarding
  }

  /// 上段 chrome（ネイティブ SwiftUI `StatusRowView` の状態）。
  let statusModel: StatusRowModel
  /// 端末ツリー（アクティブ workspace の全タブ rootContainer を WindowController が出し入れする器）。
  let content: NSView
  /// アクティブ workspace が0タブ（surface が1枚も無い）か。true のとき content の地は端末が塗らないため、
  /// AppShell が baseFill（透過設定追従）で埋める（透過ウィンドウ越しにデスクトップが透けるのを防ぐ）。
  var contentIsEmpty = false
  /// 右サイドのエディタペイン（起動時に据え、可視は cwd 追従で決める）。
  var sidePanel: NSView?
  /// facade（常駐レール）を出すか＝アクティブペインが git repo か（WindowController が投影）。
  var sideFacadeVisible = false
  /// 本体パネルが開いているか＝facade 幅が本体分を含むか（閉なら 32px レールのみ）。
  var sidePaneOpen = false
  /// ユーザーがドラッグで選んだ幅。nil = 既定（min(552px, 窓幅58%)）。
  var sideWidth: CGFloat?

  /// 前面 overlay の種別と、その描画状態（@Observable モデル）。提示元が立て下げる。
  var overlay: Overlay = .none
  var languageSelect: LanguageSelectModel?
  var workspacePalette: WorkspacePaletteModel?
  var workspaceCreate: WorkspaceCreateModel?
  var agentPalette: AgentPaletteModel?
  var dispatchPalette: DispatchPaletteModel?
  /// Dispatch の非同期データ供給元（palette と寿命を揃える。dismiss で解放）。
  var dispatchProvider: DispatchDataProvider?
  var settingsPalette: SettingsPaletteModel?
  var onboarding: OnboardingModel?

  init(statusModel: StatusRowModel, content: NSView) {
    self.statusModel = statusModel
    self.content = content
  }

  /// 現在の overlay の入力欄へ focus を再確定する（各モデルの focusToken を進め、描画後に `@FocusState` を
  /// 立て直す）。overlay 遷移（overlay→overlay・overlay→端末）では去りゆくカードの TextField（field editor）
  /// teardown が次 runloop tick に走り、同期で当てた新しい focus を奪い返す。その次 tick でここを呼び、
  /// 遷移先 overlay の入力欄へ focus を取り戻して teardown に勝つ。`.none`（端末）は host（`focusActivePane`）が担う。
  func focusCurrentOverlayField() {
    switch overlay {
    case .none: break
    case .languageSelect: languageSelect?.focus()
    case .workspacePalette: workspacePalette?.focus()
    case .workspaceCreate: workspaceCreate?.focus()
    case .agentPalette: agentPalette?.focus()
    case .dispatchPalette: dispatchPalette?.focus()
    case .settingsPalette: settingsPalette?.focus()
    case .onboarding: onboarding?.focus()
    }
  }
}

/// アプリの SwiftUI ルート。上段 chrome（固定高・ネイティブ SwiftUI）＋下段 content、
/// 右にエディタペイン（sidePanel）を配置し、前面 overlay（パレット類・オンボーディング）を `.overlay` で重ねる。
/// content/sidePanel は既存 AppKit ビューを passthrough で内包する。
struct AppShell: View {
  @Bindable var model: AppShellModel
  /// 背景透過/ブラーのホルダー（WindowController 所有）。子孫 chrome 面へ Environment で配る。
  let translucency: ChromeTranslucency
  /// 状態アイコン上書きのホルダー（WindowController 所有）。エージェント状態面 3 箇所へ Environment で配る。
  let agentIconResolver: AgentIconResolver
  /// フォント割り当てのホルダー（WindowController 所有）。chrome 全面へ Environment で配る。
  let fontResolver: ChromeFontResolver
  /// 現在言語のホルダー（WindowController 所有）。chrome 全面へ Environment で配り、言語変更で一斉再描画する。
  let localization: LocalizationStore

  var body: some View {
    ZStack {
      // 最背面の装飾層。chrome 帯・パネル余白に glow をにじませる（端末面は不透明でこの上に載る）。
      BackgroundGlow()
      VStack(spacing: 0) {
        StatusRowView(model: model.statusModel)
          .frame(height: Chrome.barHeight)
        GeometryReader { geo in
          HStack(spacing: 0) {
            NSViewContainer(view: model.content)
              // 0タブ時のみ端末と同濃度の地で埋める（surface が無く BackgroundGlow も透過時は塗らないため）。
              // baseFill は effectiveOpacity 追従なので背景不透明度の設定変更にライブで従う。タブが載れば
              // contentIsEmpty=false で clear に戻り二重 veil を避ける。
              .background(model.contentIsEmpty ? translucency.baseFill : Color.clear)
            if model.sideFacadeVisible, let sidePanel = model.sidePanel {
              NSViewContainer(view: sidePanel)
                .frame(
                  width: model.sidePaneOpen ? sideWidth(total: geo.size.width) : Chrome.railWidth)
            }
          }
        }
      }
    }
    // パレット・オンボーディング等のフルウィンドウ overlay はネイティブ SwiftUI で重ねる
    // （旧: hostingView へ NSView ファサードを addSubview）。
    .overlay { overlayView }
    // タイトルバー非表示・fullSizeContentView の窓全面を占める（chrome が信号機帯まで届く）。
    // SwiftUI 既定のタイトルバー safe-area インセットを無効化し、chrome を窓最上段まで全面レイアウトする。
    .ignoresSafeArea()
    // BackgroundGlow・StatusRow・overlay の GlassPanel が背景透過/ブラーを読む単一注入点。
    .environment(\.chromeTranslucency, translucency)
    // エージェント状態面 3 箇所（タブ行・rollup・状態カウント表）が状態アイコン上書きを読む単一注入点。
    .environment(\.agentIconResolver, agentIconResolver)
    // chrome 全面（タブ・TopBar・パレット行）がフォント割り当てを読む単一注入点。
    .environment(\.chromeFontResolver, fontResolver)
    // chrome 全面が現在言語を読む単一注入点。言語変更でこの root と全子孫が再描画される。
    .environment(\.localization, localization)
  }

  /// エディタペインの実効幅。既定は min(552px, 窓幅58%)、
  /// ドラッグ値は下限 280・上限 窓幅70% にクランプする。
  private func sideWidth(total: CGFloat) -> CGFloat {
    let base = model.sideWidth ?? min(552, total * 0.58)
    return min(max(base, 280), total * 0.7)
  }

  @ViewBuilder private var overlayView: some View {
    switch model.overlay {
    case .none:
      EmptyView()
    case .languageSelect:
      if let m = model.languageSelect { LanguageSelectOverlay(model: m) }
    case .workspacePalette:
      if let palette = model.workspacePalette { PaletteOverlay(model: palette.render) }
    case .workspaceCreate:
      if let create = model.workspaceCreate { WorkspaceCreateOverlay(model: create) }
    case .agentPalette:
      if let palette = model.agentPalette { PaletteOverlay(model: palette.render) }
    case .dispatchPalette:
      if let palette = model.dispatchPalette { DispatchOverlay(model: palette) }
    case .settingsPalette:
      if let palette = model.settingsPalette { PaletteOverlay(model: palette.render) }
    case .onboarding:
      if let onboarding = model.onboarding { OnboardingOverlay(model: onboarding) }
    }
  }
}
