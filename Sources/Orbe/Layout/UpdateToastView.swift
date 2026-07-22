import SwiftUI

/// アップデートの「準備完了」トースト（見本 2a）。再起動待ちになった瞬間に一度だけ右下へ出る非モーダル層
/// （提示条件は `UpdateState.toastVisible`＝1 バージョンにつき一度）。**明示的に閉じるまで残る**——
/// 適用は再起動/終了時で、ターミナルは何日も起動しっぱなしが普通のため、時間で消える通知は役目に
/// 対して儚すぎる（非モーダルな右下の小さな面なので残っても邪魔にならない）。閉じる操作は
/// ✕・「今すぐ再起動」・「変更内容」（シートが開けば情報の受け取りが成立）のいずれか。
/// ✕ も放置も同じ結果（終了時適用）——「今すぐ再起動」は近道であって義務ではない。
struct UpdateToastView: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n

  var body: some View {
    GlassPanel(level: .popup, cornerRadius: Theme.Radius.card) {
      HStack(alignment: .top, spacing: Theme.Space.beat - 1) {
        // 状態アイコン（waiting の淡塗り円＋↑）。語彙は状態カードと同じ waiting（再起動待ち）。
        Text("↑")
          .font(Font.theme.label)
          .foregroundStyle(Color.theme.stateWaiting)
          .frame(width: 28, height: 28)
          .background(Circle().fill(Color.theme.tintWaiting))
          .overlay(
            Circle().strokeBorder(
              Color.theme.stateWaiting.opacity(0.4), lineWidth: Theme.Stroke.hairline))

        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
            Text(l10n.string(.updateToastTitle))
              .font(Font.theme.labelStrong)
              .foregroundStyle(Color.theme.textPrimary)
              .lineLimit(1)
            Spacer(minLength: 0)
            Button {
              state.dismissToast()
            } label: {
              Text("✕")
                .font(Font.theme.label)
                .foregroundStyle(Color.theme.textMuted)
            }
            .buttonStyle(.plain)
          }
          subtitle
            .padding(.top, Theme.Space.hair + 1)
          HStack(spacing: Theme.Space.bar - 2) {
            Button {
              state.onRestartNow()
            } label: {
              Text(l10n.string(.updateRestartNow))
                .font(Font.theme.caption.weight(.semibold))
                .foregroundStyle(Color.theme.accentPrimary)
            }
            .buttonStyle(.plain)
            Button {
              state.onShowChanges()
            } label: {
              Text(l10n.string(.updateShowChanges))
                .font(Font.theme.caption.weight(.semibold))
                .foregroundStyle(Color.theme.textMuted)
            }
            .buttonStyle(.plain)
          }
          .padding(.top, Theme.Space.step + 1)
        }
      }
      .padding(.top, Theme.Space.beat + 1)
      .padding(.horizontal, Theme.Space.beat + 2)
      .padding(.bottom, Theme.Space.bar - 1)
      .frame(width: 340, alignment: .leading)
    }
  }

  /// 「vX.Y.Z — 次回終了時に自動で適用されます」。バージョンは一段明るい secondary（見本の ver 表記）。
  private var subtitle: some View {
    let version = state.ready.map { "v\($0.version)" } ?? ""
    let tail = l10n.string(
      state.autoInstallOnQuit ? .updateToastAutoApply : .updateToastManualApply)
    return
      (Text(version).foregroundStyle(Color.theme.textSecondary)
      + Text(" — \(tail)").foregroundStyle(Color.theme.textMuted))
      .font(Font.theme.codeSmall)
      .lineLimit(1)
  }
}
