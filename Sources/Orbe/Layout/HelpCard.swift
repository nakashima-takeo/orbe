import SwiftUI

/// フルウィンドウ overlay。help scrim（最暗幕）＋中央配置のヘルプカード。
/// scrim タップで閉じる（⌘H トグルの閉じ側は WindowController のキー経路が担う）。
struct HelpOverlay: View {
  @Bindable var model: HelpModel

  /// カードの基準寸法（デザイン見本のモーダル上限 760×656。窓が狭ければ −32 マージンで縮む）。
  private let cardWidth: CGFloat = 760
  private let cardHeight: CGFloat = 656

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Scrim(strength: .help)
          .contentShape(Rectangle())
          .onTapGesture { model.onDismiss() }
        HelpCard(model: model)
          .frame(
            width: min(cardWidth, geo.size.width - Theme.Space.bar * 2),
            height: min(cardHeight, geo.size.height - Theme.Space.bar * 2))
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
      }
    }
    .onChange(of: model.focusToken, initial: true) { fieldFocused = true }
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
        .foregroundStyle(Color.theme.textMuted)
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.hair)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(ink.surface(0.04)))
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.beat)
  }

  /// キー絞り込みチップ（accent 淡塗り・accentBright 文字）。タップで解除。
  private func keyFilterChip(_ fkey: String) -> some View {
    HStack(spacing: 5) {
      Text(l10n.format(.helpKeyFilterChip, HelpCatalog.symbol(for: fkey)))
      Text("×").opacity(0.7)
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.accentBright)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, Theme.Space.step)
    .padding(.vertical, Theme.Space.hair)
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
