import SwiftUI

/// トップビュー（基本操作）。見出し行＋2カラムグリッド（厳選 3 グループ＋エージェントステータス凡例）。
/// 行ホバーで accent 淡塗り＋キーボード点灯（`model.hoverRow`）。
struct HelpTopView: View {
  @Bindable var model: HelpModel
  let ink: HelpInk
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(l10n.string(.helpCatBasics))
          .font(Font.theme.helpTitle)
          .foregroundStyle(Color.theme.textPrimary)
        Text(l10n.string(.helpTopSubtitle))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      .padding(.bottom, Theme.Space.tick)
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 26, alignment: .topLeading),
          GridItem(.flexible(), alignment: .topLeading),
        ],
        alignment: .leading, spacing: Theme.Space.note
      ) {
        ForEach(HelpCatalog.topGroups, id: \.title) { group in
          topGroup(group)
        }
        legend
      }
    }
    .padding(.top, 10)
    .padding(.bottom, Theme.Space.hair)
  }

  private func topGroup(_ group: HelpCatalog.Group) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HelpSectionLabel(text: l10n.string(group.title))
        .padding(.top, Theme.Space.beat)
        .padding(.bottom, 5)
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        ForEach(group.rows, id: \.key) { row in
          HelpTopRow(model: model, ink: ink, group: group, row: row)
        }
      }
    }
  }

  /// エージェントステータス凡例（実グリフ `StatusGlyphView`・状態色）。ラベル語（working 等）は非翻訳。
  private var legend: some View {
    VStack(alignment: .leading, spacing: 0) {
      HelpSectionLabel(text: l10n.string(.helpLegendTitle))
        .padding(.top, Theme.Space.beat)
        .padding(.bottom, 5)
      VStack(alignment: .leading, spacing: 5) {
        legendRow(.working, "working", .helpLegendWorking)
        legendRow(.waiting, "waiting", .helpLegendWaiting)
        legendRow(.done, "done", .helpLegendDone)
        legendRow(.idle, "idle", .helpLegendIdle)
      }
    }
  }

  private func legendRow(_ kind: AgentStateIcon.Kind, _ name: String, _ desc: L10nKey) -> some View
  {
    HStack(spacing: 9) {
      StatusGlyphView(kind: kind, size: 13)
        .frame(width: 15)
      Text(name)
        .font(Font.theme.helpRow)
        .foregroundStyle(Color.theme.textPrimary)
        .frame(width: 62, alignment: .leading)
      Text(l10n.string(desc))
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
    }
  }
}

/// トップビューの 1 行（キーバッジ＋ラベル）。ホバーで accent 0.12 塗り＋キーボード点灯。
private struct HelpTopRow: View {
  @Bindable var model: HelpModel
  let ink: HelpInk
  let group: HelpCatalog.Group
  let row: HelpCatalog.Row
  @Environment(\.localization) private var l10n

  private var rowID: String { "top/\(group.title.rawValue)/\(row.key)" }

  var body: some View {
    HStack(spacing: 9) {
      Text(row.key)
        .font(Font.theme.chrome)
        .tracking(Theme.Typography.trackingKey)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        .fixedSize()
        // tracking は末尾グリフの後にも付くため、その分だけ trailing を詰めて光学中央を保つ。
        .padding(.trailing, -Theme.Typography.trackingKey)
        .padding(.horizontal, 7)
        .padding(.vertical, Theme.Space.hair)
        .frame(minWidth: 46)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(ink.surface(0.07)))
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .strokeBorder(ink.border(0.14), lineWidth: Theme.Stroke.hairline))
      Text(l10n.string(row.label))
        .font(Font.theme.helpRow)
        .foregroundStyle(Color.theme.textSecondary)
        .lineLimit(1)
    }
    .padding(.vertical, Theme.Space.hair)
    .padding(.horizontal, Theme.Space.step)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          model.pressedRowIDs.contains(rowID)
            ? Color.theme.accentPrimary.opacity(0.16)
            : model.hoverRow?.id == rowID
              ? Color.theme.accentPrimary.opacity(0.12) : Color.clear)
    )
    // 実押下一致のハイライト枠（キーボード点灯と同期。ホバーの塗りと同系＋accent 枠で区別）。
    .overlay {
      if model.pressedRowIDs.contains(rowID) {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.theme.accentPrimary.opacity(0.4), lineWidth: Theme.Stroke.hairline)
      }
    }
    // デザインの margin 0 -8px 相当: 塗りは左右 8px はみ出し、テキストは列に揃う。
    .padding(.horizontal, -Theme.Space.step)
    .id(rowID)
    .onHover { entered in
      if entered {
        model.hoverRow = (id: rowID, combo: row.combo)
      } else if model.hoverRow?.id == rowID {
        model.hoverRow = nil
      }
    }
  }
}

/// 一覧ビュー。検索 × カテゴリ × キー絞り込み（AND）で残ったグループを見出し付きで縦に並べる。
/// 行ホバーで accent 淡塗り＋キーボード点灯（`model.hoverRow`）。
struct HelpListView: View {
  @Bindable var model: HelpModel
  let ink: HelpInk
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(model.filteredGroups(l10n), id: \.title) { group in
        HelpSectionLabel(text: l10n.string(group.title))
          .padding(.top, 10)
          .padding(.bottom, Theme.Space.tick)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(group.rows, id: \.key) { row in
            HelpListRow(model: model, ink: ink, group: group, row: row)
          }
        }
      }
    }
  }
}

/// 一覧ビューの 1 行（ラベル左・キーバッジ右）。ホバーで accent 0.1 塗り。
private struct HelpListRow: View {
  @Bindable var model: HelpModel
  let ink: HelpInk
  let group: HelpCatalog.Group
  let row: HelpCatalog.Row
  @Environment(\.localization) private var l10n

  /// トップと一覧で同キーが別行になるため、行 id はビュー/グループ/キーの合成で衝突させない。
  private var rowID: String { "\(group.title.rawValue)/\(row.key)" }

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      Text(l10n.string(row.label))
        .font(Font.theme.helpRow)
        .foregroundStyle(Color.theme.textSecondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      // 外形はデザインの CSS 外形（padding 2px 7px ＋ border 1px が外に付く）と同寸=
      // 幅 text+16 / 高さ 18。SwiftUI は stroke が内側なので padding 8・高さ 18 で寸を合わせる。
      Text(row.key)
        .font(Font.theme.helpKeyList)
        .tracking(Theme.Typography.trackingKey)
        .foregroundStyle(Color.theme.statusText)
        .lineLimit(1)
        .fixedSize()
        // tracking は末尾グリフの後にも付くため、その分だけ trailing を詰めて光学中央を保つ。
        .padding(.trailing, -Theme.Typography.trackingKey)
        .padding(.horizontal, Theme.Space.step)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(ink.surface(0.06)))
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .strokeBorder(ink.border(0.12), lineWidth: Theme.Stroke.hairline))
    }
    .padding(.vertical, Theme.Space.tick)
    .padding(.horizontal, Theme.Space.step)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          model.pressedRowIDs.contains(rowID)
            ? Color.theme.accentPrimary.opacity(0.16)
            : model.hoverRow?.id == rowID
              ? Color.theme.accentPrimary.opacity(0.1) : Color.clear)
    )
    // 実押下一致のハイライト枠（キーボード点灯と同期。ホバーの塗りと同系＋accent 枠で区別）。
    .overlay {
      if model.pressedRowIDs.contains(rowID) {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.theme.accentPrimary.opacity(0.4), lineWidth: Theme.Stroke.hairline)
      }
    }
    // デザインの margin 0 -8px 相当: 塗りは左右 8px はみ出し、テキストは列に揃う。
    .padding(.horizontal, -Theme.Space.step)
    .id(rowID)
    .onHover { entered in
      if entered {
        model.hoverRow = (id: rowID, combo: row.combo)
      } else if model.hoverRow?.id == rowID {
        model.hoverRow = nil
      }
    }
  }
}

/// グループ見出し（9pt・大文字・tracking 1・muted）。トップと一覧で共用する。
struct HelpSectionLabel: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .font(Font.theme.helpSection)
      .tracking(Theme.Typography.trackingLabel)
      .foregroundStyle(Color.theme.textMuted)
  }
}
