import SwiftUI

/// アップデートの「準備完了」トースト（見本 2a）。再起動待ちになった瞬間に一度だけ右下へ出る非モーダル層
/// （提示条件は `UpdateState.toastVisible`＝1 バージョンにつき一度）。10 秒で自動消滅し、ホバー中は
/// カウントを止める。✕ も放置も同じ結果（終了時適用）——「今すぐ再起動」は近道であって義務ではない。
struct UpdateToastView: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n
  /// 残り時間（1.0 → 0.0）。下端の細いラインの幅がこれに追従する。
  @State private var remaining: Double = 1.0
  @State private var hovering = false

  /// 自動消滅までの秒数（見本 2a の設計注記「10秒で消え、ホバー中はカウント停止」）。
  private let lifetime: Double = 10
  private let tick: Double = 0.1
  private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

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
                .font(Font.theme.meta)
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
      // 下端の細いライン＝自動消滅までの残り時間（見本 2a）。
      .overlay(alignment: .bottomLeading) {
        GeometryReader { geo in
          Rectangle()
            .fill(Color.theme.stateWaiting.opacity(0.45))
            .frame(width: geo.size.width * remaining, height: 2)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
      }
    }
    .onHover { hovering = $0 }
    .onReceive(timer) { _ in
      guard !hovering else { return }
      remaining = max(0, remaining - tick / lifetime)
      if remaining <= 0 { state.dismissToast() }
    }
  }

  /// 「vX.Y.Z — 次回終了時に自動で適用されます」。バージョンだけ mono（見本の ver 表記）。
  private var subtitle: some View {
    let version = state.ready.map { "v\($0.version)" } ?? ""
    let tail = l10n.string(
      state.autoInstallOnQuit ? .updateToastAutoApply : .updateToastManualApply)
    return (Text(version).font(Font.theme.codeSmall) + Text(" — \(tail)").font(Font.theme.meta))
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
  }
}
