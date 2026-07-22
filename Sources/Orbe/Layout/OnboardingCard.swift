import SwiftUI

/// 初回起動オンボーディングの状態（@Observable・§5.9）。検出した CLI を見せてデフォルトを選ばせ、
/// 状態追跡プラグインの導入を per-CLI のライブ進捗で見せる。流れの駆動と導入実行は AgentLauncher が
/// 持ち、本モデルは表示状態と入力意味だけ。AgentCLI には依存せず command 文字列だけ持つ
/// （View を app ロジックから切る）。描画は `OnboardingOverlay`（`AppShell` の `.overlay` が compose）。
@Observable final class OnboardingModel {
  enum Status { case waiting, installing, done, failed, skipped }
  enum Phase { case select, installing }

  var phase: Phase = .select
  /// CLI 検出が未完了か（select フェーズでスピナーを見せ、確定操作を止める）。
  var detecting: Bool = false
  /// 検出した CLI の command 名（表示順）。
  var agentCommands: [String] = []
  /// デフォルトに選ぶ index（select フェーズ）。
  var selected = 0
  /// per-CLI の導入状態（installing フェーズ）。
  var statuses: [String: Status] = [:]
  /// focus トリガ。提示元がインクリメントし、SwiftUI が監視して `@FocusState` を立てる。
  var focusToken = 0

  /// ↵ / 行タップ / 「始める」押下（select フェーズの選択を AgentLauncher が解決する）。
  var onBegin: () -> Void = {}

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { focusToken &+= 1 }

  /// 検出結果を反映（裏の再検出が届いたときの再読込にも使う）。select フェーズのみ意味を持つ。
  func setCommands(_ commands: [String]) {
    agentCommands = commands
    if selected >= commands.count { selected = 0 }
  }

  /// 導入フェーズへ。全 CLI を「待機」で並べる。
  func beginInstalling() {
    phase = .installing
    statuses = Dictionary(uniqueKeysWithValues: agentCommands.map { ($0, Status.waiting) })
  }

  /// per-CLI の導入状態を更新。
  func setStatus(_ command: String, _ status: Status) {
    statuses[command] = status
  }

  /// 選択移動（select フェーズのみ）。
  func move(_ direction: Int) {
    guard phase == .select, !agentCommands.isEmpty else { return }
    selected = min(max(0, selected + direction), agentCommands.count - 1)
  }

  /// select フェーズの先頭/末尾へジャンプ（d<0=先頭・d>=0=末尾。導入中・空は no-op）。
  func jump(_ d: Int) {
    guard phase == .select, !agentCommands.isEmpty else { return }
    selected = d < 0 ? 0 : agentCommands.count - 1
  }

  /// ↵ / 「始める」。select フェーズのみ（導入中・検出中は無視）。
  func activate() {
    guard phase == .select, !detecting else { return }
    onBegin()
  }

  /// 行タップ＝決定。選択をその行へ確定してから ↵ と同じ funnel（`activate()`）を通す。
  func activate(at index: Int) {
    guard agentCommands.indices.contains(index) else { return }
    selected = index
    activate()
  }

  /// 導入フェーズの母集団は agentCommands（検出済みのみ）。install.sh は未検出 CLI にも
  /// skip イベントを出すが、それは進捗に数えない（分子・分母の母集団を一致させる）。
  var settledCount: Int {
    agentCommands.filter { command in
      guard let status = statuses[command] else { return false }
      return status != .waiting && status != .installing
    }.count
  }
  var hasFailures: Bool {
    agentCommands.contains { statuses[$0] == .failed }
  }
}

/// オンボーディングのカード（§5.9）。中身だけ。全面 scrim・中央寄せは host 側が担う。
/// select=検出 CLI を並べデフォルトを選ばせる／installing=per-CLI のライブ進捗。
struct OnboardingCard: View {
  @Bindable var model: OnboardingModel
  @Environment(\.localization) private var l10n

  var body: some View {
    GlassPanel(level: .settings) {
      VStack(alignment: .leading, spacing: Theme.Space.bar) {
        Text(title)
          .font(Font.theme.title)
          .foregroundStyle(Color.theme.textPrimary)

        VStack(spacing: 0) {
          switch model.phase {
          case .select: selectRows
          case .installing: installingRows
          }
        }

        HStack(spacing: Theme.Space.beat) {
          Text(hint)
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
          Spacer(minLength: 0)
          if model.phase == .select, !model.detecting {
            Button(l10n.string(.onboardingBegin)) { model.activate() }
              .buttonStyle(DSPrimaryButtonStyle())
          }
        }
      }
      .padding(Theme.Space.phrase)
      .frame(width: 440, alignment: .leading)
    }
  }

  // MARK: - select

  @ViewBuilder private var selectRows: some View {
    if model.detecting {
      HStack(spacing: Theme.Space.beat) {
        ProgressView().controlSize(.small)
        Text(l10n.string(.onboardingDetecting))
          .font(Font.theme.label)
          .foregroundStyle(Color.theme.textMuted)
        Spacer(minLength: 0)
      }
      .padding(.vertical, Theme.Space.step)
      .padding(.horizontal, Theme.Space.beat)
    } else if model.agentCommands.isEmpty {
      PaletteRow(
        title: l10n.string(.agentNotFoundCLI),
        showsChevron: false, kind: .info)
    } else {
      PaletteRow(title: l10n.string(.onboardingIntro), showsChevron: false, kind: .info)
      ForEach(Array(model.agentCommands.enumerated()), id: \.offset) { i, command in
        PaletteRow(
          title: command, selected: i == model.selected, showsChevron: false,
          action: { model.activate(at: i) }, onHoverEnter: { model.selected = i })
      }
    }
  }

  // MARK: - installing

  @ViewBuilder private var installingRows: some View {
    ForEach(Array(model.agentCommands.enumerated()), id: \.offset) { _, command in
      let status = model.statuses[command] ?? .waiting
      HStack(spacing: Theme.Space.beat) {
        StatusIcon(status: status)
          .frame(width: 16, height: 16)
        Text(command)
          .font(Font.theme.label)
          .foregroundStyle(Color.theme.textSecondary)
          .strikethrough(status == .skipped)
        Spacer(minLength: 0)
        Text(statusLabel(status))
          .font(Font.theme.caption)
          .foregroundStyle(Color.theme.textMuted)
      }
      .padding(.vertical, Theme.Space.step)
      .padding(.horizontal, Theme.Space.beat)
    }
  }

  private var title: String {
    switch model.phase {
    case .select: return l10n.string(.onboardingWelcome)
    case .installing:
      return l10n.format(.onboardingInstalling, model.settledCount, model.agentCommands.count)
    }
  }

  private var hint: String {
    switch model.phase {
    case .select:
      if model.detecting { return l10n.string(.onboardingHintDetecting) }
      return model.agentCommands.isEmpty
        ? l10n.string(.onboardingHintBegin) : l10n.string(.onboardingHintSelectBegin)
    case .installing: return ""
    }
  }

  private func statusLabel(_ status: OnboardingModel.Status) -> String {
    switch status {
    case .waiting: return l10n.string(.onboardingStatusWaiting)
    case .installing: return l10n.string(.onboardingStatusInstalling)
    case .done: return l10n.string(.onboardingStatusDone)
    case .failed: return l10n.string(.onboardingStatusFailed)
    case .skipped: return l10n.string(.onboardingStatusSkipped)
    }
  }
}

/// 導入状態の行頭アイコン（§5.9）。done=✓青 / failed=✗赤（緑は使わない）。
private struct StatusIcon: View {
  let status: OnboardingModel.Status

  var body: some View {
    switch status {
    case .waiting:
      Image(systemName: "circle.fill")
        .font(.system(size: 6))
        .foregroundStyle(Color.theme.textMuted)
    case .installing:
      ProgressView().controlSize(.small)
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.theme.success)
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(Color.theme.danger)
    case .skipped:
      Image(systemName: "minus.circle").foregroundStyle(Color.theme.textMuted)
    }
  }
}

/// フルウィンドウ overlay。dim scrim ＋ 中央のカード。真のモーダルで、scrim はヒットを吸収するだけ
/// （クリックで閉じない）。前進は「始める」/↵/行タップ。↑↓ でデフォルト選択。
/// 入力欄が無いためカード器を `.focusable()` にしてキーを捕捉する。
struct OnboardingOverlay: View {
  @Bindable var model: OnboardingModel
  @FocusState private var focused: Bool

  var body: some View {
    ZStack {
      Scrim(strength: .strong)
        .contentShape(Rectangle())
      OnboardingCard(model: model)
    }
    .ignoresSafeArea()
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    // 矢印は単一の catch-all に集約し ⌘ 有無で先頭/末尾ジャンプと 1 行移動を分岐する。
    .onKeyPress { press in
      switch press.key {
      case .upArrow:
        if press.modifiers.contains(.command) { model.jump(-1) } else { model.move(-1) }
        return .handled
      case .downArrow:
        if press.modifiers.contains(.command) { model.jump(1) } else { model.move(1) }
        return .handled
      default:
        return .ignored
      }
    }
    .onKeyPress(.return) {
      model.activate(); return .handled
    }
    .onChange(of: model.focusToken, initial: true) { focused = true }
  }
}

#Preview("Onboarding — select") {
  let model = OnboardingModel()
  model.agentCommands = ["claude", "codex", "agy"]
  model.selected = 0
  return OnboardingCard(model: model).padding(Theme.Space.phrase)
}
