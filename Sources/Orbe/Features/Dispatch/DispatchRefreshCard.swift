import SwiftUI

/// Dispatch カードの最新化モードの中身（ヘッダ中身・2 行の本文・フッター）。器は `DispatchCard` が持つ。
///
/// 選択・最新化中・作成中・失敗は**同じ 2 行の別の時点**で、失敗した「最新化して作成」だけが clean の
/// 一部失敗の行と同じ部品（✕・danger 面・再試行）を着る。git の生の出力は載せず理由だけを言う。

/// 失敗の文言の導き方（モデルは事実だけを持つ）。
enum DispatchRefreshFailureText {
  /// 落ちた段（git 語。訳さない）。
  static func step(_ failure: GitRefreshFailure) -> String {
    switch failure {
    case .fetch: return "fetch"
    case .fastForward: return "fast-forward"
    }
  }

  /// 理由。git が言い残した実質行はそのまま、打ち切りと分岐（git は黙る）は chrome の文で。
  static func reason(_ failure: GitRefreshFailure, upstream: GitUpstream, _ l10n: LocalizationStore)
    -> String
  {
    switch failure {
    case .fetch(.reason(let reason)), .fastForward(.some(.reason(let reason))): return reason
    case .fetch(.timedOut), .fastForward(.some(.timedOut)): return l10n.string(.gitTimedOut)
    case .fastForward(nil): return l10n.format(.dispatchRefreshDiverged, upstream.short)
    }
  }
}

/// 最新化のヘッダ中身。名前＋遅れ（失敗時は理由）の一文が説明を兼ねる（本文は 2 行しか無い）。
struct DispatchRefreshHeader: View {
  @Bindable var model: DispatchRefreshModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      (fontResolver.text(model.sync.name, base: Theme.Typography.title)
        .foregroundStyle(Color.theme.textPrimary)
        + Text(" " + subtitle).foregroundStyle(Color.theme.textMuted))
        .font(Font.theme.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      if let failure = model.failure {
        pill(
          Text("✕ " + DispatchRefreshFailureText.step(failure)), CleanTone.danger.fill,
          CleanTone.danger.foreground)
      } else {
        pill(
          SyncCountLabel(
            direction: .down, count: model.sync.behind, em: Theme.Typography.meta.pointSize),
          Color.theme.tintAccent, Color.theme.accentPrimary)
      }
      if !model.isBusy {
        Text(l10n.string(.dispatchCleanBack))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
      }
    }
  }

  private var subtitle: String {
    if let failure = model.failure {
      return l10n.format(
        .dispatchRefreshFailedHeader,
        DispatchRefreshFailureText.reason(failure, upstream: model.sync.upstream, l10n))
    }
    return l10n.format(
      model.sync.behind == 1 ? .dispatchRefreshBehindOne : .dispatchRefreshBehindOther,
      model.sync.upstream.short, model.sync.behind)
  }

  private func pill(_ content: some View, _ background: Color, _ foreground: Color) -> some View {
    content
      .font(Font.theme.meta)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .padding(.vertical, Theme.Space.hair + 1)
      .background(Capsule().fill(background))
  }
}

/// 最新化の本文。見出し 1 本＋ 2 行で、パレットはその高さに縮む。
struct DispatchRefreshList: View {
  @Bindable var model: DispatchRefreshModel
  let onConfirm: (DispatchStaleChoice) -> Void
  let onHover: (DispatchStaleChoice) -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(l10n.string(.dispatchRefreshSection).uppercased())
        .font(Font.theme.sectionLabel)
        .tracking(Theme.Typography.trackingLabel)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.top, Theme.Space.step)
        .padding(.horizontal, 10)
        .padding(.bottom, 3)
      DispatchRefreshRow(
        model: model, choice: .refreshed, onTap: { onConfirm(.refreshed) },
        onHoverEnter: { onHover(.refreshed) })
      DispatchRefreshRow(
        model: model, choice: .asIs, onTap: { onConfirm(.asIs) }, onHoverEnter: { onHover(.asIs) })
    }
    .padding(Theme.Space.note)
    .background(
      GeometryReader { geometry in
        Color.clear.preference(key: DispatchContentHeightKey.self, value: geometry.size.height)
      }
    )
  }
}

/// 最新化の 1 行。レイアウトは一覧の行と同一（gap 8・padding 5×10・radius 8）。
struct DispatchRefreshRow: View {
  @Bindable var model: DispatchRefreshModel
  let choice: DispatchStaleChoice
  /// 行タップ＝決定（一覧の行と同じ）。
  let onTap: () -> Void
  /// ホバー開始＝選択の追従（決定は走らない）。効くかどうかは入力モダリティが握る（→ `ModalSelection`）。
  let onHoverEnter: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  private var cursor: Bool { model.choice == choice }
  private var failure: GitRefreshFailure? { choice == .refreshed ? model.failure : nil }

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      glyph.frame(width: 14, alignment: .center)
      Text(l10n.string(choice == .refreshed ? .dispatchRefreshTitle : .dispatchRefreshAsIsTitle))
        .font(Font.theme.workspaceName)
        .foregroundStyle(
          cursor || failure != nil ? Color.theme.textPrimary : Color.theme.textSecondary
        )
        .lineLimit(1)
        .fixedSize()
      fontResolver.text(description, base: Theme.Typography.meta)
        .font(Font.theme.meta)
        .foregroundStyle(failure != nil ? CleanTone.danger.foreground : Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      if failure != nil { trailing }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(fill))
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .onHover { if $0 { onHoverEnter() } }
  }

  private var fill: Color {
    if cursor { return Color.theme.selectionFill }
    return failure != nil ? CleanTone.danger.fill : .clear
  }

  /// 行頭 14 幅: 行 0 は ↓（失敗時 ✕）、行 1 は Local branch のグリフ。
  @ViewBuilder private var glyph: some View {
    switch choice {
    case .refreshed where failure != nil:
      Text("✕").font(Font.theme.chrome).foregroundStyle(CleanTone.danger.foreground)
    case .refreshed:
      SyncArrowView(direction: .down, em: Theme.Typography.workspaceName.pointSize)
        .foregroundStyle(Color.theme.accentPrimary)
    case .asIs:
      Text("⎇").font(Font.theme.chrome).foregroundStyle(Color.theme.textMuted)
    }
  }

  private var description: String {
    switch choice {
    case .refreshed:
      if let failure {
        return l10n.format(
          .dispatchRefreshFailedDesc, DispatchRefreshFailureText.step(failure),
          DispatchRefreshFailureText.reason(failure, upstream: model.sync.upstream, l10n))
      }
      return l10n.format(.dispatchRefreshDesc, model.sync.upstream.short)
    case .asIs:
      return l10n.format(.dispatchRefreshAsIsDesc, model.sync.name, model.item.detail ?? "")
    }
  }

  /// 失敗した行 0 の右端: 同期ピル＋再試行。通常時の右端は空（既定行は初期選択で伝わる）。
  private var trailing: some View {
    HStack(spacing: Theme.Space.tick) {
      DispatchSyncPills(sync: model.sync)
      CleanCapsule(text: l10n.string(.dispatchRefreshRetry), active: false)
        .font(Font.theme.sectionLabel)
    }
    .fixedSize()
  }
}

/// 最新化のフッター。相だけで分岐する——最新化中と作成中は一覧の作成中と同じ busy 部品で、
/// 選択・失敗はカーソル行連動の実行説明（前置句だけが 2 択の側を言う）＋キーヒント。
struct DispatchRefreshFooter: View {
  @Bindable var model: DispatchRefreshModel
  /// 選択中の起動先名（⇥ は効かないので画面の間は変わらない）。
  let targetName: String
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      switch model.phase {
      case .updating:
        DispatchBusyLabel(text: l10n.format(.dispatchRefreshing, model.sync.upstream.short))
        Spacer(minLength: 0)
      case .creating:
        DispatchBusyLabel(text: l10n.string(.dispatchPreparing))
        Spacer(minLength: 0)
      case .choosing, .failed:
        DispatchLaunchLine(
          target: model.sync.name,
          preposition: model.choice == .refreshed ? .dispatchPrepRefreshed : .dispatchPrepAsIs,
          agent: targetName)
        Spacer(minLength: Theme.Space.step)
        HStack(spacing: Theme.Space.step + Theme.Space.hair) {
          DispatchKeyHint(key: "↑↓", label: l10n.string(.dispatchHintSelect))
          if model.failure != nil {
            DispatchKeyHint(key: "r", label: l10n.string(.dispatchHintRetry))
          }
          DispatchKeyHint(key: "esc", label: l10n.string(.dispatchHintBack))
        }
        .font(Font.theme.sectionLabel)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
        .layoutPriority(1)
      }
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.step + Theme.Space.hair)
  }
}
