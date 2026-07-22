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
    formatter.locale = Locale(identifier: l10n.language == .ja ? "ja_JP" : "en_US")
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return l10n.format(.updateLastChecked, formatter.string(from: date))
  }
}

/// 最上段の状態カード。5 状態（確認中 / DL中 / 最新 / 失敗 / 適用待ち）＋ idle（最新表示へ縮退）。
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
          ProgressView().controlSize(.small)
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
            Text(l10n.format(.updateStateDownloading, "v\(state.ready?.version ?? "")"))
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
          Button(l10n.string(.updateRetry)) { state.onCheckNow() }
            .buttonStyle(DSSecondaryButtonStyle())
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
    case .idle, .upToDate:
      shell(border: Color.theme.stateDone.opacity(0.24)) {
        HStack(spacing: Theme.Space.step + 1) {
          Text("✓")
            .font(Font.theme.caption)
            .foregroundStyle(Color.theme.stateDone)
          Text(l10n.string(.updateStateUpToDate))
            .font(Font.theme.label)
            .foregroundStyle(Color.theme.textPrimary)
          Spacer(minLength: 0)
          (Text("v\(state.currentVersion)").font(Font.theme.meta)
            + Text(" · " + UpdateLastCheckText.string(state.lastCheck, l10n)))
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
        }
      }
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

/// 「今すぐ確認」行（枠だけのセカンダリボタン意匠・行全幅）。確認中はスピナーへ替わる（見本 2d 注記）。
struct UpdateCheckNowRow: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      if case .checking = state.phase {
        ProgressView().controlSize(.small)
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
    .padding(.vertical, Theme.Space.tick)
  }
}
