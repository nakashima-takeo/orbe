import SwiftUI

/// フルウィンドウ overlay。help scrim（最暗幕）＋中央配置のヘルプカード。
/// scrim タップで閉じる（⌘H トグルの閉じ側は WindowController のキー経路が担う）。
struct HelpOverlay: View {
  @Bindable var model: HelpModel

  /// カードの基準寸法（デザイン見本のモーダル上限 760×656。窓が狭ければ −32 マージンで縮む）。
  private let cardWidth: CGFloat = 760
  private let cardHeight: CGFloat = 656
  /// 内部リフローが成立する最小カード寸（床）。幅はキーボード可視化の実寸（約 570＋左右 16）、
  /// 高さはヘッダ＋キーボード＋フッター＋サイドバー実寸が決める。design 見本は縮小域を定義しない
  /// ため Orbe の設計: 床まではリフローで縮み、床を下回る小窓ではカードを床寸で描いて等倍縮小する
  /// （レイアウトは常に成立し、design の構成が崩れない）。
  private let floorWidth: CGFloat = 608
  private let floorHeight: CGFloat = 540

  var body: some View {
    GeometryReader { geo in
      let availWidth = max(1, geo.size.width - Theme.Space.bar * 2)
      let availHeight = max(1, geo.size.height - Theme.Space.bar * 2)
      let width = max(floorWidth, min(cardWidth, availWidth))
      let height = max(floorHeight, min(cardHeight, availHeight))
      let scale = min(1, availWidth / width, availHeight / height)
      ZStack {
        Scrim(strength: .help)
          .contentShape(Rectangle())
          .onTapGesture { model.onDismiss() }
        HelpCard(model: model)
          .frame(width: width, height: height)
          .scaleEffect(scale)
          // レイアウト境界を縮小後の視覚寸法に合わせる（ZStack の中央配置と当たり判定を一致させる）。
          .frame(width: width * scale, height: height * scale)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .ignoresSafeArea()
  }
}

/// デザイン見本の rgba 面/罫線（surfaceRgb / borderRgb の α 合成）を基色トークン＋view 側 α で再現する
/// ヘルパ。light では border +0.04 / surface +0.02 シフト（EditorPane と同じ「基色＋view 側 α」方式）。
struct HelpInk {
  let dark: Bool

  func border(_ alpha: CGFloat) -> Color {
    Color.theme.borderInk.opacity(dark ? alpha : alpha + 0.04)
  }

  func surface(_ alpha: CGFloat) -> Color {
    Color.theme.surfaceInk.opacity(dark ? alpha : alpha + 0.02)
  }
}

/// ヘルプのカード本体。縦構成＝ヘッダ（検索・チップ・件数・⌘H バッジ）/（サイドバー＋コンテンツ）/ フッター。
/// 外郭は `GlassPanel(.help)`（面 α.92・radius16・panel 級 blur・help 影）。
/// キーは検索欄（常時フォーカス）に集約し、esc で閉じる（1段。デザイン見本の2段挙動は採らない）。
struct HelpCard: View {
  @Bindable var model: HelpModel
  @Environment(\.localization) private var l10n
  @Environment(\.colorScheme) private var scheme
  @FocusState private var fieldFocused: Bool

  /// サイドバー幅（デザイン見本の 168px。コンポーネント局所定数）。
  private let sidebarWidth: CGFloat = 168

  private var ink: HelpInk { HelpInk(dark: scheme == .dark) }

  /// フッター・サイドバー下端の実行バージョン表記。Orbe バンドル外の実行（swift build 直起動・
  /// preview・テスト）はホスト側の版数が紛れ込むため `dev` に固定する。
  static let version: String = {
    guard Bundle.main.bundleIdentifier?.hasPrefix("dev.orbe") == true,
      let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    else { return "dev" }
    return v
  }()

  var body: some View {
    GlassPanel(level: .help) {
      VStack(spacing: 0) {
        header
        ink.border(0.08).frame(height: Theme.Stroke.hairline)
        HStack(spacing: 0) {
          sidebar
          ink.border(0.08).frame(width: Theme.Stroke.hairline)
          content
        }
        .frame(maxHeight: .infinity)
        ink.border(0.06).frame(height: Theme.Stroke.hairline)
        HelpKeyboardView(model: model, ink: ink)
        ink.border(0.08).frame(height: Theme.Stroke.hairline)
        footer
      }
    }
    .onChange(of: model.focusToken, initial: true) { fieldFocused = true }
    .onChange(of: model.pressed) { model.syncPressedMatch(l10n) }
  }

  // MARK: - フッター

  private var footer: some View {
    HStack(spacing: 14) {
      Text(l10n.string(.helpFooterType))
      HStack(spacing: Theme.Space.tick) {
        Text("esc").foregroundStyle(Color.theme.textPrimary)
        Text(l10n.string(.helpFooterEscClose))
      }
      Spacer(minLength: Theme.Space.step)
      Text("orbe \(Self.version)").opacity(0.6)
    }
    .font(Font.theme.helpSection)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, 9)
  }

  // MARK: - ヘッダ（検索・キー絞り込みチップ・件数・⌘H バッジ）

  private var header: some View {
    HStack(spacing: 10) {
      Text("❯")
        .font(Font.theme.helpTitle)
        .foregroundStyle(Color.theme.accentPrimary)
      queryField
      if let fkey = model.fkey {
        keyFilterChip(fkey)
      }
      if !model.isTopView {
        Text(l10n.plural(hitCount, one: .helpHitCountOne, other: .helpHitCountOther))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      Text("⌘H")
        .font(Font.theme.meta)
        .tracking(Theme.Typography.trackingKey)
        .foregroundStyle(Color.theme.textMuted)
        // tracking は末尾グリフの後にも付くため、その分だけ trailing を詰めて光学中央を保つ。
        .padding(.trailing, -Theme.Typography.trackingKey)
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.hair)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(ink.surface(0.04)))
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.beat)
  }

  /// キー絞り込みチップ（accent 淡塗り・accentBright 文字）。タップで解除。
  /// 外形はデザインの CSS 外形（padding 2px 8px ＋ border 1px が外に付く）と同寸=
  /// 幅 text+18 / 高さ 18。SwiftUI は stroke が内側なので padding 9・高さ 18 で寸を合わせる。
  private func keyFilterChip(_ fkey: String) -> some View {
    HStack(spacing: 5) {
      Text(l10n.format(.helpKeyFilterChip, HelpCatalog.symbol(for: fkey)))
      Text("×").opacity(0.7)
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.accentBright)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 9)
    .frame(height: 18)
    .background(Capsule().fill(Color.theme.accentPrimary.opacity(0.16)))
    .overlay(
      Capsule().strokeBorder(
        Color.theme.accentPrimary.opacity(0.4), lineWidth: Theme.Stroke.hairline)
    )
    .contentShape(Capsule())
    .onTapGesture { model.fkey = nil }
  }

  /// 検索欄。開いた瞬間から入力可能（そのままタイプで検索）。esc は常に閉じる。
  private var queryField: some View {
    TextField("", text: $model.query)
      .textFieldStyle(.plain)
      .font(Font.theme.helpTitle)
      .foregroundStyle(Color.theme.textPrimary)
      .tint(Color.theme.accentPrimary)
      .focused($fieldFocused)
      .imePlaceholder(
        l10n.string(.helpSearchPlaceholder), showWhenEmpty: model.query.isEmpty,
        focused: fieldFocused, font: Font.theme.helpTitle, color: Color.theme.textMuted
      )
      .frame(maxWidth: .infinity)
      .onKeyPress(.escape) {
        model.onDismiss()
        return .handled
      }
  }

  /// 一覧ビューのヒット件数（検索 × カテゴリ × キー絞り込みの AND）。
  private var hitCount: Int {
    model.filteredGroups(l10n).reduce(0) { $0 + $1.rows.count }
  }

  // MARK: - サイドバー（カテゴリ）

  private struct SidebarItem: Identifiable {
    let category: HelpModel.Category
    let name: String
    let count: String
    var id: HelpModel.Category { category }
  }

  private var sidebarItems: [SidebarItem] {
    [
      SidebarItem(category: .top, name: l10n.string(.helpCatBasics), count: ""),
      SidebarItem(
        category: .all, name: l10n.string(.helpCatAllShortcuts),
        count: "\(HelpCatalog.totalCount)"),
    ]
      + HelpCatalog.all.map {
        SidebarItem(
          category: .group($0.title), name: l10n.string($0.title), count: "\($0.rows.count)")
      }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: Theme.Space.hair) {
      ForEach(sidebarItems) { item in
        HelpSidebarRow(
          name: item.name, count: item.count, selected: model.category == item.category,
          action: { model.category = item.category })
      }
      Spacer(minLength: 0)
      Text("orbe \(Self.version)")
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .opacity(0.6)
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Space.note)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, Theme.Space.step)
    .frame(width: sidebarWidth, alignment: .topLeading)
  }

  // MARK: - コンテンツ（トップビュー ⇔ 一覧ビュー）

  private var content: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if model.isTopView {
            HelpTopView(model: model, ink: ink)
          } else {
            HelpListView(model: model, ink: ink)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, Theme.Space.note)
        .padding(.horizontal, 18)
        .padding(.bottom, Theme.Space.beat)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // 実押下一致の行が画面外なら自動スクロールで見せる。カテゴリ自動遷移と同時に立つことが
      // あるため、次 tick（新しい一覧のレイアウト後）に寄せてから scrollTo する。
      .onChange(of: model.revealRowID) { _, id in
        guard let id else { return }
        DispatchQueue.main.async {
          withAnimation(.linear(duration: Theme.Motion.quick)) {
            proxy.scrollTo(id, anchor: .center)
          }
        }
      }
    }
  }
}

/// サイドバーの 1 行（カテゴリ名＋件数）。選択＝accent 0.14・ホバー＝0.1。
private struct HelpSidebarRow: View {
  let name: String
  let count: String
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      Text(name)
        .font(Font.theme.helpSidebarItem)
        .foregroundStyle(selected ? Color.theme.textPrimary : Color.theme.textMuted)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(count)
        .font(Font.theme.helpCount)
        .foregroundStyle(Color.theme.textMuted)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, Theme.Space.note)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(
          selected
            ? Color.theme.accentPrimary.opacity(0.14)
            : hovering ? Color.theme.accentPrimary.opacity(0.1) : Color.clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onTapGesture(perform: action)
    .onHover { hovering = $0 }
  }
}

#if DEBUG
  /// 見た目検証用の共通ステージ（design 原典と同寸 920×720・BackgroundGlow の上に overlay ごと描く）。
  private func helpPreview(_ configure: (HelpModel) -> Void = { _ in }) -> some View {
    let model = HelpModel()
    configure(model)
    return ZStack {
      BackgroundGlow()
      HelpOverlay(model: model)
    }
    .frame(width: 920, height: 720)
  }

  #Preview("Help — top") {
    helpPreview()
  }

  #Preview("Help — list (all)") {
    helpPreview { $0.category = .all }
  }

  #Preview("Help — search") {
    helpPreview { $0.query = "タブ" }
  }

  #Preview("Help — keyboard lit") {
    helpPreview { model in
      model.fkey = "t"
      model.pressed = ["cmd", "shift"]
    }
  }

  #Preview("Help — pressed match") {
    helpPreview { model in
      model.pressed = ["cmd", "r"]
      model.syncPressedMatch(LocalizationStore(language: .ja))
    }
  }
#endif
