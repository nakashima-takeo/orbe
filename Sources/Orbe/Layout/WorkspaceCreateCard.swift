import SwiftUI

/// フルウィンドウ overlay。normal scrim（暗幕＋blur）＋上端 66pt アンカーの作成カード（切替パレットと同位置で
/// 「その場が差し替わる」体験）。カード幅= min(560, 窓幅−32)。scrim タップで閉じる（＝切替画面へ戻す・clone 待機中は無視）。
struct WorkspaceCreateOverlay: View {
  @Bindable var model: WorkspaceCreateModel

  /// カード上端の窓上端からの距離・カードの基準幅（切替パレット＝WorkspaceSwitcher と同値）。
  private let topAnchor: CGFloat = 66
  private let cardWidth: CGFloat = 560

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        Scrim(strength: .normal)
          .contentShape(Rectangle())
          .onTapGesture { if !model.isCloning { model.onDismiss() } }  // clone 待機中は無視
        WorkspaceCreateCard(model: model)
          .frame(width: min(cardWidth, geo.size.width - Theme.Space.bar * 2))
          .padding(.top, topAnchor)
          .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
  }
}

/// 作成フォームのカード本体。ヘッダ（◐＋「新規ワークスペース」＋「esc 戻る」ピル）／ソース切替タブ（既存フォルダ /
/// git clone）／本文（ソース別）／フッター（案内＋「キャンセル」「作成して開く」）。外郭は `GlassPanel(.panel)`。
/// folder のキーはパス欄／名前欄の `TextField` に集約し、↑↓（補完移動）・⇥（補完確定 or 名前欄へ）・esc・↵ を捌く。
/// clone 本文とソースタブ・clone 案内は `WorkspaceCreateCard+Clone.swift`（`WorkspaceCreateCloneForm`）に置く。
struct WorkspaceCreateCard: View {
  @Bindable var model: WorkspaceCreateModel
  // 別ファイルの extension（WorkspaceCreateCard+Clone）も読むため internal。
  @Environment(\.localization) var l10n
  private enum Field { case path, name }
  @FocusState private var focus: Field?

  /// 補完ドロップダウンの高さ上限（px・見本 maxHeight 186。超過は内部スクロール）。
  private let suggestionCap: CGFloat = 186

  var body: some View {
    GlassPanel(level: .panel) {
      VStack(alignment: .leading, spacing: 0) {
        header
        divider
        sourceTabs
        formBody
        cloneErrorBanner
        divider
        footer
      }
    }
    // folder のとき主入力欄（パス）へ focus を確定する。clone は subview が自前の focus を握る。
    // 代入は次 runloop tick へ回す——提示直後・ソースタブクリック直後は、新規 mount 直後で field editor が
    // 未準備／クリックが focus をさらった状態で、同期代入だと focus が乗らない。次 tick で確実に当てる。
    .onChange(of: model.focusToken, initial: true) {
      guard model.source == .folder else { return }
      DispatchQueue.main.async { focus = .path }
    }
  }

  /// esc / キャンセル / scrim の畳み込み。clone 実行中は無視（待機を割り込ませない）。
  private func dismissIfIdle() {
    guard !model.isCloning else { return }
    model.onDismiss()
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  // MARK: - ヘッダ

  private var header: some View {
    HStack(spacing: Theme.Space.beat) {
      Text("◐")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.glyphGradient)
      Text(l10n.string(.wsCreateTitle))
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.textPrimary)
      Spacer(minLength: Theme.Space.step)
      Text(l10n.string(.wsCreateEscBack))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.hair)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.smallPillFill))
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  // MARK: - 本文（ソース別）

  /// ソースで本文を差し替える。clone は subview（待機表示の分岐は subview 内）。
  @ViewBuilder private var formBody: some View {
    switch model.source {
    case .folder: folderBody
    case .clone: WorkspaceCreateCloneForm(model: model)
    }
  }

  // MARK: - 本文（既存フォルダ：パス・名前）

  private var folderBody: some View {
    VStack(alignment: .leading, spacing: Theme.Space.bar) {
      pathSection
      nameSection
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  private var pathSection: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      workspaceFieldLabel(l10n.string(.wsFieldPath))
      pathField
      if !model.suggestions.isEmpty { suggestionsDropdown }
    }
  }

  private var pathField: some View {
    TextField("", text: pathBinding)
      .textFieldStyle(.plain)
      .font(Font.theme.code)
      .foregroundStyle(Color.theme.textPrimary)
      .tint(Color.theme.accentPrimary)
      .focused($focus, equals: .path)
      .modifier(FieldChrome(focused: focus == .path))
      // ↑↓＝補完ハイライト移動、⌘↑↓＝先頭/末尾候補へジャンプ、⇥＝候補ありなら確定・無ければ名前欄へ、
      // esc＝候補ありなら閉じる・無ければ戻る、↵＝候補ありなら確定・無ければ作成。
      // 矢印は単一の catch-all に集約し ⌘ 有無で分岐する（bare ハンドラが ⌘↑ を食う不確実性を構造で排除）。
      .onKeyPress { press in
        switch press.key {
        case .upArrow:
          if press.modifiers.contains(.command) {
            model.jumpHighlight(-1)
          } else {
            model.moveHighlight(-1)
          }
          return .handled
        case .downArrow:
          if press.modifiers.contains(.command) {
            model.jumpHighlight(1)
          } else {
            model.moveHighlight(1)
          }
          return .handled
        default:
          return .ignored
        }
      }
      .onKeyPress(.tab) {
        if model.acceptSuggestion() { return .handled }
        focus = .name
        return .handled
      }
      .onKeyPress(.escape) {
        if model.dismissSuggestions() { return .handled }  // 候補ありなら閉じるだけ
        dismissIfIdle()  // 候補なしなら前の画面へ
        return .handled
      }
      .onSubmit {
        if model.suggestions.isEmpty {
          model.submit()  // 候補なし → 作成
        } else {
          model.acceptSuggestion()  // 候補あり → 確定
        }
      }
  }

  private var pathBinding: Binding<String> {
    Binding(get: { model.path }, set: { model.setPath($0) })
  }

  private var suggestionsDropdown: some View {
    // 器は popup 級（見本 rgba(panelRgb,.95)・radius 10）。行は full-bleed（見本 overflow:hidden で
    // 器の角丸に食い込む）＝行側に角丸・余白を持たせず、選択塗りは器いっぱいに敷く。
    GlassPanel(level: .popup) {
      VStack(alignment: .leading, spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { entry in
                suggestionRow(index: entry.offset, suggestion: entry.element).id(entry.offset)
              }
            }
          }
          .frame(maxHeight: suggestionCap)
          .fixedSize(horizontal: false, vertical: true)
          .scrollIndicators(.automatic)
          .onChange(of: model.highlighted) { proxy.scrollTo(model.highlighted) }
        }
        divider
        suggestionFooter
      }
    }
  }

  /// 見本のドロップダウン下端: 左にキーヒント（idle）・右端へ件数（muted）を marginLeft auto で寄せる。
  private var suggestionFooter: some View {
    HStack(spacing: Theme.Space.beat) {
      Text(l10n.string(.wsHintMove))
      Text(l10n.string(.wsHintComplete))
      Spacer(minLength: Theme.Space.step)
      Text(
        l10n.plural(
          model.suggestions.count, one: .wsSuggestionCountOne, other: .wsSuggestionCountOther)
      )
      .foregroundStyle(Color.theme.textMuted)
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.stateIdle)
    .padding(.horizontal, Theme.Space.beat)
    .padding(.vertical, Theme.Space.note)
  }

  private func suggestionRow(index: Int, suggestion: FolderSuggestion) -> some View {
    let selected = index == model.highlighted
    let nameColor = selected ? Color.theme.textPrimary : Color.theme.textSecondary
    return HStack(spacing: Theme.Space.step) {
      Text("▸")
        .font(Font.theme.workspaceName)
        .foregroundStyle(selected ? Color.theme.accentPrimary : Color.theme.stateIdle)
      // フォルダ名＋末尾に淡いスラッシュ（見本の orbe/ ＝ディレクトリの符牒）。
      (Text(suggestion.name).foregroundColor(nameColor)
        + Text("/").foregroundColor(Color.theme.stateIdle))
        .font(Font.theme.workspaceName)
        .lineLimit(1)
        .layoutPriority(1)
      Text((suggestion.fullPath as NSString).abbreviatingWithTildeInPath)
        .font(Font.theme.meta)
        .foregroundStyle(selected ? Color.theme.textMuted : Color.theme.stateIdle)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.tick)
      if suggestion.isRepo {
        // 見本: 素の green テキスト（ピル塗りにしない）。
        Text("git")
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.diffAdded)
      }
    }
    .padding(.horizontal, Theme.Space.beat)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? Color.theme.selectionFill : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture {
      model.highlighted = index
      model.acceptSuggestion()
    }
  }

  private var nameSection: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      HStack(spacing: Theme.Space.step) {
        workspaceFieldLabel(l10n.string(.wsFieldName))
        Spacer(minLength: 0)
        WorkspaceNameLinkStatus(model: model, followLabel: l10n.string(.wsFollowPath))
      }
      nameField
    }
  }

  private var nameField: some View {
    TextField("", text: nameBinding)
      .textFieldStyle(.plain)
      .font(Font.theme.code)  // パス欄と同一（見本は両欄同寸・type.code=入力）
      .foregroundStyle(Color.theme.stateDone)  // 見本: 名前欄の文字は done(green)
      .tint(Color.theme.accentPrimary)
      .focused($focus, equals: .name)
      .modifier(FieldChrome(focused: focus == .name))
      .onKeyPress(.escape) {
        dismissIfIdle()
        return .handled
      }
      .onSubmit { model.submit() }
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { model.curName },
      set: { edited in
        guard edited != model.curName else { return }
        model.setName(edited)
      })
  }

  // MARK: - フッター

  private var footer: some View {
    HStack(spacing: Theme.Space.beat) {
      footerGuide
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      // clone 待機中は 2 ボタンとも無効（キャンセル不可・完了まで待機）。
      Button(l10n.string(.commonCancel)) { dismissIfIdle() }
        .buttonStyle(DSSecondaryButtonStyle())
        .disabled(model.isCloning)
      Button(l10n.string(.wsCreateOpen)) { model.submit() }
        .buttonStyle(DSPrimaryButtonStyle())
        .disabled(!model.canCreate || model.isCloning)
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  /// フッター案内（ソース別）。clone 側は `WorkspaceCreateCard+Clone.swift`。
  @ViewBuilder private var footerGuide: some View {
    switch model.source {
    case .folder: folderGuide
    case .clone: cloneGuide
    }
  }

  /// folder: 実在時は「作成すると {name}(done) ({path})(idle) が開きます」(muted 基調)。
  /// 不在時は muted の注記に差し替える（不在パスは「作成して開く」も無効）。
  @ViewBuilder private var folderGuide: some View {
    if model.pathExists {
      (Text(l10n.string(.wsCreateGuideLead)).foregroundColor(Color.theme.textMuted)
        + Text(model.curName).foregroundColor(Color.theme.stateDone)
        + Text(" (\((model.path as NSString).abbreviatingWithTildeInPath))")
        .foregroundColor(Color.theme.stateIdle)
        + Text(l10n.string(.wsCreateGuideOpenTail)).foregroundColor(Color.theme.textMuted))
        .font(Font.theme.workspaceName)
    } else {
      Text(l10n.string(.wsFolderMissing))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
    }
  }
}

/// 入力欄のラベル（見本: 11px muted ラベル・letterSpacing 0.08em ≒ tracking 1）。folder/clone で共用。
func workspaceFieldLabel(_ text: String) -> some View {
  Text(text)
    .font(Font.theme.chrome)
    .tracking(Theme.Typography.trackingLabel)
    .foregroundStyle(Color.theme.textMuted)
}

/// 入力欄の共通装飾（inputWash 地・角丸・focus で accent 半透明枠／非 focus で border トークン枠）。
/// α が外観で切れない `.opacity()` は focus 枠のみ（accent は動的色で uniform に効く）。地・枠色は
/// `DesignSystem` トークンへ写像し、生 hex を直書きしない。folder/clone の入力欄で共用。
struct FieldChrome: ViewModifier {
  let focused: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, 11)  // 見本の入力欄高（padding 11px・off-grid の指定値）
      .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.theme.inputWash))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .strokeBorder(
            focused ? Color.theme.accentPrimary.opacity(0.5) : Color.theme.inputBorder,
            lineWidth: Theme.Stroke.hairline)
      )
  }
}

#if DEBUG
  #Preview("WorkspaceCreate — follow + complete") {
    let model = WorkspaceCreateModel(path: "~/github/or")
    model.suggestions = [
      FolderSuggestion(name: "orbe", fullPath: "/Users/me/github/orbe", isRepo: true),
      FolderSuggestion(
        name: "orbe-worktrees", fullPath: "/Users/me/github/orbe-worktrees", isRepo: false),
    ]
    return ZStack {
      BackgroundGlow()
      WorkspaceCreateOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }

  #Preview("WorkspaceCreate — unlinked") {
    let model = WorkspaceCreateModel(path: "~/github/orbe")
    model.setName("my-workspace")
    return ZStack {
      BackgroundGlow()
      WorkspaceCreateOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }
#endif
