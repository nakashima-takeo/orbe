import SwiftUI

/// コマンド/ワークスペースパレットの行（§5）。
/// default=text.secondary / selected=text.primary＋tint 塗り（hover 独自の着色は持たず、
/// ホバーは呼び出し側が `onHoverEnter` で選択を追従させる）/
/// dormant=減光(.45) / info=選択不可・text.muted / createAction=accent 文字＋破線罫線＋右端バッジ。
/// detail はラベル後の muted 補足（ディレクトリ等）。
struct PaletteRow: View {
  /// 行の性質。`info` は選択不可の情報行（CLI 無し等）。`createAction` は作成導線の行（表示専用装飾）。
  enum Kind { case normal, dormant, info, createAction }

  let title: String
  var selected: Bool = false
  var showsChevron: Bool = true
  var kind: Kind = .normal
  /// 設定パレット workspace スコープで global 継承中の行（未上書き）。非選択時に淡色で区別する。
  var inherited: Bool = false
  /// 行頭（タイトルの手前）に置く付属ビュー（状態アイコンのプレビューグリフ等）。nil で出さない。
  var leading: AnyView?
  /// ラベル後に muted で出す補足（workspace 行のディレクトリ等）。
  var detail: String?
  /// 行末に出す表示専用バッジ（作成導線の `⌘N` 等）。nil で出さない。
  var trailingBadge: String?
  var action: () -> Void = {}
  /// ホバー開始（enter）通知。`SelectableRow` へ透過し、呼び出し側が選択追従に結ぶ。
  var onHoverEnter: () -> Void = {}

  /// フォント割り当て（絵文字 run 等）。主名/補足のユーザー由来文字列（workspace 名・ファイル名）に効く。
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    switch kind {
    case .info:
      HStack {
        Text(title)
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textMuted)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)

    case .normal, .dormant:
      SelectableRow(selected: selected, action: action, onHoverEnter: onHoverEnter) {
        HStack(spacing: Theme.Space.step) {
          if let leading {
            leading
          }
          fontResolver.text(title, base: Theme.Typography.workspaceName)
            .font(Font.theme.workspaceName)
            .foregroundStyle(labelColor)
            .lineLimit(1)
            .layoutPriority(1)  // 主名が先に幅を取り、溢れは補足（detail）から省略される
          if let detail, !detail.isEmpty {
            fontResolver.text(detail, base: Theme.Typography.meta)
              .font(Font.theme.meta)
              .foregroundStyle(Color.theme.textMuted)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer(minLength: 0)
          if showsChevron {
            Text("›")
              .font(Font.theme.workspaceName)
              .foregroundStyle(Color.theme.textMuted)
          }
        }
      }
      .opacity(kind == .dormant && !selected ? Theme.Opacity.dormant : 1)

    case .createAction:
      SelectableRow(selected: selected, action: action, onHoverEnter: onHoverEnter) {
        HStack(spacing: Theme.Space.step) {
          Text(title)
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.accentPrimary)
            .lineLimit(1)
            .layoutPriority(1)
          Spacer(minLength: 0)
          if let trailingBadge {
            Text(trailingBadge)
              .font(Font.theme.meta)
              .foregroundStyle(Color.theme.textMuted)
              .padding(.horizontal, Theme.Space.step)
              .padding(.vertical, Theme.Space.hair)
              .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.smallPillFill))
          }
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .strokeBorder(
            Color.theme.createDashBorder,
            style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: [4, 3]))
      )
      .padding(.top, Theme.Space.note)  // 見本: 直上の行から 6pt 空けて作成導線を分離（marginTop 6）
    }
  }

  private var labelColor: Color {
    if selected { return Color.theme.textPrimary }
    return inherited ? Color.theme.textMuted : Color.theme.textSecondary  // 継承中は淡色
  }
}

#Preview("PaletteRow") {
  VStack(spacing: 0) {
    PaletteRow(title: "orbe-core", selected: true, detail: "~/dev/orbe")
    PaletteRow(title: "ghostty-fork", detail: "~/dev/ghostty")
    PaletteRow(title: "notes", detail: "~/notes")
    PaletteRow(title: "gemini (dormant)", kind: .dormant)
    PaletteRow(title: "No CLIs found", showsChevron: false, kind: .info)
  }
  .padding(Theme.Space.note)
  .frame(width: 480)
  .background(Color.theme.bgBase)
  .padding(Theme.Space.phrase)
  .background(Color.theme.bgSunken)
}
