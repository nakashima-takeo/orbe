import SwiftUI

/// 設定›アップデート（見本 2c/2d）の行コンテンツ群。`SettingsPaletteModel+Update` が
/// `RowItem.customContent` として組み、キー操作（↵/→）は palette 側の行活性が担う。
/// ビューは `UpdateState`（@Observable）を直接読むため、進捗・状態遷移は行再構築なしでライブに追従する。

/// 最終確認時刻の表示（"たった今" / "今日 21:04"）。状態カードとバージョン行が共有する語彙。
enum UpdateLastCheckText {
  static func string(_ date: Date?, _ l10n: LocalizationStore) -> String {
    guard let date else { return l10n.string(.updateLastCheckedNever) }
    if Date().timeIntervalSince(date) < 60 {
      return l10n.format(.updateLastChecked, l10n.string(.relativeJustNow))
    }
    let formatter = DateFormatter()
    formatter.locale = l10n.language.dateLocale
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return l10n.format(.updateLastChecked, formatter.string(from: date))
  }
}

/// `.idle`（このセッションでまだ何も起きていない）の見え 2 通り。カードもテストもここを読む。
/// updater が動いていないビルドは確認そのものが走らないため「確認しない」と言い、それ以外は
/// 「まだ確認していない」と言う——どちらも「最新です」ではない。
enum UpdateIdleAppearance: Equatable {
  /// まだ確認していない（最終確認時刻を添える）。
  case notChecked
  /// このビルドでは確認しない（起動ゲートを通らなかった）。
  case checkDisabled

  static func resolve(_ availability: UpdateState.CheckAvailability) -> UpdateIdleAppearance {
    availability == .unavailable ? .checkDisabled : .notChecked
  }

  var label: L10nKey {
    switch self {
    case .notChecked: return .updateStateNotChecked
    case .checkDisabled: return .updateStateCheckDisabled
    }
  }

  /// 中立の状態点（notChecked）はカード族の書式「状態色 × 0.24」、更新の経路そのものが無い
  /// （checkDisabled）は状態色を持たない中立ヘアライン。
  var border: Color {
    switch self {
    case .notChecked: return Color.theme.stateIdle.opacity(0.24)
    case .checkDisabled: return Color.theme.surface1
    }
  }
}

/// 最上段の状態カード。7 通りの見え（まだ確認していない / 確認しない / 確認中 / DL中 / 最新 / 失敗 /
/// 適用待ち）。`.idle` は確認の可否で 2 つに分かれる（`UpdateIdleAppearance`）。
/// トーストに出るのは「適用待ち」だけで、他の状態はここにしか現れない（見本 2d）。
struct UpdateStatusCardRow: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n

  var body: some View {
    card
      .padding(.vertical, Theme.Space.hair)
  }

  @ViewBuilder private var card: some View {
    switch state.phase {
    case .checking:
      shell(border: Color.theme.surface1) {
        HStack(spacing: Theme.Space.step + 1) {
          StatusGlyphView(kind: .working, size: 10)
          Text(l10n.string(.updateStateChecking))
            .font(Font.theme.label)
            .foregroundStyle(Color.theme.textPrimary)
          Spacer(minLength: 0)
        }
      }
    case .downloading(let received, let total):
      shell(border: Color.theme.stateWorking.opacity(0.26)) {
        VStack(alignment: .leading, spacing: Theme.Space.step + 1) {
          HStack(spacing: Theme.Space.step + 1) {
            dot(Color.theme.stateWorking)
            Text(l10n.format(.updateStateDownloading, "v\(state.downloadVersion ?? "")"))
              .font(Font.theme.label)
              .foregroundStyle(Color.theme.textPrimary)
            Spacer(minLength: 0)
            Text("\(UpdateByteText.string(received)) / \(UpdateByteText.string(total))")
              .font(Font.theme.meta)
              .foregroundStyle(Color.theme.textMuted)
          }
          GeometryReader { geo in
            Capsule().fill(Color.theme.surface2)
              .overlay(alignment: .leading) {
                Capsule()
                  .fill(Color.theme.stateWorking)
                  .frame(width: total > 0 ? geo.size.width * Double(received) / Double(total) : 0)
              }
          }
          .frame(height: 4)
        }
      }
    case .failed:
      shell(border: Color.theme.danger.opacity(0.28)) {
        HStack(alignment: .center, spacing: Theme.Space.step + 1) {
          dot(Color.theme.danger)
          VStack(alignment: .leading, spacing: Theme.Space.hair) {
            Text(l10n.string(.updateStateFailedTitle))
              .font(Font.theme.label)
              .foregroundStyle(Color.theme.textPrimary)
            Text(l10n.string(.updateStateFailedHint))
              .font(Font.theme.meta)
              .foregroundStyle(Color.theme.textMuted)
          }
          Spacer(minLength: 0)
          // 再試行は「今すぐ確認」と同じ導線＝同じ可否に従う。押せない間は disabled の減光で示す
          // （行の「今すぐ確認」と同じ register）。
          Button(l10n.string(.updateRetry)) { state.onCheckNow() }
            .buttonStyle(DSSecondaryButtonStyle())
            .disabled(!state.canCheckNow)
        }
      }
    case .readyToRestart:
      shell(fill: Color.theme.tintWaiting, border: Color.theme.stateWaiting.opacity(0.3)) {
        VStack(alignment: .leading, spacing: Theme.Space.note) {
          HStack(spacing: Theme.Space.step) {
            dot(Color.theme.stateWaiting)
            Text(l10n.format(.updateStateWaiting, "v\(state.ready?.version ?? "")"))
              .font(Font.theme.labelStrong)
              .foregroundStyle(Color.theme.textPrimary)
            Spacer(minLength: 0)
            Button(l10n.string(.updateRestartNow)) { state.onRestartNow() }
              .buttonStyle(DSPrimaryButtonStyle())
          }
          HStack(spacing: Theme.Space.tick) {
            Text(
              l10n.string(
                state.autoInstallOnQuit ? .updateWaitingApplyOnQuit : .updateWaitingApplyManual)
                + " ·"
            )
            .foregroundStyle(Color.theme.textMuted)
            Button {
              state.onShowChanges()
            } label: {
              Text(l10n.string(.updateShowChanges))
                .foregroundStyle(Color.theme.accentPrimary)
            }
            .buttonStyle(.plain)
          }
          .font(Font.theme.meta)
        }
      }
    case .idle:
      shell(border: idleAppearance.border) {
        HStack(spacing: Theme.Space.step + 1) {
          idleGlyph(idleAppearance)
          Text(l10n.string(idleAppearance.label))
            .font(Font.theme.label)
            .foregroundStyle(Color.theme.textPrimary)
          Spacer(minLength: 0)
          // 確認しないビルドは右端に何も出さない。バージョンと最終確認時刻は直下の情報行が持つ。
          if idleAppearance == .notChecked {
            (Text("v\(state.currentVersion)").foregroundStyle(Color.theme.textSecondary)
              + Text(" · " + UpdateLastCheckText.string(state.lastCheck, l10n))
              .foregroundStyle(Color.theme.textMuted))
              .font(Font.theme.meta)
          }
        }
      }
    case .upToDate:
      shell(border: Color.theme.stateDone.opacity(0.24)) {
        HStack(spacing: Theme.Space.step + 1) {
          Text("✓")
            .font(Font.theme.caption)
            .foregroundStyle(Color.theme.stateDone)
          Text(l10n.string(.updateStateUpToDate))
            .font(Font.theme.label)
            .foregroundStyle(Color.theme.textPrimary)
          Spacer(minLength: 0)
          (Text("v\(state.currentVersion)").foregroundStyle(Color.theme.textSecondary)
            + Text(" · " + UpdateLastCheckText.string(state.lastCheck, l10n))
            .foregroundStyle(Color.theme.textMuted))
            .font(Font.theme.meta)
        }
      }
    }
  }

  private var idleAppearance: UpdateIdleAppearance { .resolve(state.checkAvailability) }

  @ViewBuilder private func idleGlyph(_ appearance: UpdateIdleAppearance) -> some View {
    switch appearance {
    case .notChecked:
      dot(Color.theme.stateIdle)
    case .checkDisabled:
      // カード族のグリフは実寸＝スロット幅（`StatusGlyphView` と同じ契約）。SF Symbol の素の
      // advance は側方ベアリングを含んで dot より広く、ラベルの左端が notChecked とずれるため、
      // dot と同じ 8pt スロットへ固定して円環の直径も dot の直径に揃える。
      Image(systemName: "minus.circle")
        .font(.system(size: 8))
        .frame(width: 8, height: 8)
        .foregroundStyle(Color.theme.textMuted)
    }
  }

  private func dot(_ color: Color) -> some View {
    Circle().fill(color).frame(width: 8, height: 8)
  }

  private func shell(
    fill: Color = Color.theme.bgSunken, border: Color, @ViewBuilder content: () -> some View
  ) -> some View {
    content()
      .padding(.vertical, Theme.Space.beat)
      .padding(.horizontal, Theme.Space.beat + 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(fill))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .strokeBorder(border, lineWidth: Theme.Stroke.hairline))
  }
}

/// 現在バージョン＋最終確認時刻の情報行（見本 2c。選択・実行の対象にしない）。
struct UpdateVersionRow: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        Text(l10n.string(.updateCurrentVersion))
          .font(Font.theme.body)
          .foregroundStyle(Color.theme.textSecondary)
        Text(UpdateLastCheckText.string(state.lastCheck, l10n))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      Spacer(minLength: 0)
      Text("v\(state.currentVersion)")
        .font(Font.theme.code)
        .foregroundStyle(Color.theme.textPrimary)
    }
    .padding(.vertical, Theme.Space.note)
  }
}

/// トグル行（ラベル＋補足＋ピル。見本 2c の 3 トグル）。値は行構築時点のスナップショットで、
/// 切替は palette 側が行を組み直して反映する（root の toggle 行と同じ流儀）。
struct UpdateToggleRow: View {
  let title: String
  let subtitle: String
  let isOn: Bool

  var body: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        Text(title)
          .font(Font.theme.body)
          .foregroundStyle(Color.theme.textSecondary)
        Text(subtitle)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      Spacer(minLength: 0)
      Capsule()
        .fill(isOn ? Color.theme.stateDone : Color.theme.surface2)
        .frame(width: 32, height: 19)
        .overlay(alignment: isOn ? .trailing : .leading) {
          Circle()
            .fill(Color.theme.bgBase)
            .frame(width: 15, height: 15)
            .padding(2)
        }
    }
    .padding(.vertical, Theme.Space.note)
  }
}

/// 「今すぐ確認」行の見え方。可否と phase から決まる単一の規則で、行ビューもテストもここを読む。
enum UpdateCheckNowAppearance: Equatable {
  /// 通常表示（押せる）。
  case actionable
  /// スピナー＋「アップデートを確認中…」。実際に確認が走っているときだけ名乗る。
  case checking
  /// 減光（押しても走らない）。理由は隣の状態カードが持つか、updater が動いていない。
  case dimmed

  static func resolve(_ state: UpdateState) -> UpdateCheckNowAppearance {
    if case .checking = state.phase { return .checking }
    switch state.checkAvailability {
    case .available:
      return .actionable
    case .busy:
      // セッション進行中。状態カードが進行中の確認を語らない（まだ確認していない/最新/失敗＝
      // いま走っている確認については何も言わない）ときだけ行が「確認中…」を名乗る——事実そのとおり
      // 確認中のため。
      switch state.phase {
      case .downloading, .readyToRestart: return .dimmed
      case .idle, .checking, .upToDate, .failed: return .checking
      }
    case .unavailable:
      // updater が動いていない＝確認は走っていない。「確認中…」を名乗らせない。
      return .dimmed
    }
  }
}

/// 「今すぐ確認」行（枠だけのセカンダリボタン意匠・行全幅）。3 態は `UpdateCheckNowAppearance`。
struct UpdateCheckNowRow: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n

  private var appearance: UpdateCheckNowAppearance { .resolve(state) }

  /// 部分的な色替えではなく行ごと `Opacity.disabled` へ落とす（§5 ボタン disabled と同じ register）。
  private var dimmed: Bool { appearance == .dimmed }

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      if appearance == .checking {
        StatusGlyphView(kind: .working, size: 10)
        Text(l10n.string(.updateStateChecking))
          .font(Font.theme.caption)
          .foregroundStyle(Color.theme.textMuted)
      } else {
        Text(l10n.string(.updateCheckNow))
          .font(Font.theme.caption)
          .foregroundStyle(Color.theme.textSecondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Space.step - 1)
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .strokeBorder(Color.theme.surface2, lineWidth: Theme.Stroke.hairline)
    )
    .opacity(dimmed ? Theme.Opacity.disabled : 1)
    .padding(.vertical, Theme.Space.tick)
  }
}
