import SwiftUI

// clean の 1 行。**3 画面は同じ行の別の時点**なので、行頭のグリフと meta 列だけが入れ替わり、
// 器（padding 5×10・radius 8・gap 8・13px の行頭・末尾省略の meta）は共通の契約として保つ。

/// 選択画面の 1 行（＋チェックすると開くサブライン）。
/// **背景ハイライトはカーソル行だけ**——チェック状態は ✓ ボックスの塗りだけが示す（背景で二重に示さない）。
struct DispatchCleanRow: View {
  @Bindable var model: DispatchCleanModel
  let row: CleanRow
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  private var inUse: Bool { row.group == .inUse }
  private var cursor: Bool { model.cursorRow?.id == row.id }
  private var expanded: Bool { model.isExpanded(row) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      main
      if expanded { subline }
    }
    .id(row.id)
  }

  private var main: some View {
    HStack(spacing: Theme.Space.step) {
      if inUse {
        // inUse 行はボックス自体を描かず、同幅の空スペーサで名前の頭を揃える。
        Color.clear.frame(width: 13, height: 13)
      } else {
        CleanCheckbox(isOn: model.isChecked(row))
      }
      // 縮む順は meta → 名前 → 右クラスタ（優先度 0 < 1 < 2）。どれも 1 行で末尾省略し、
      // 折り返さない。行の最小幅を提案幅より小さく保てないと、器のカードが窓を超えて広がる。
      fontResolver.text(row.name, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(cursor ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      // meta 列はブランチ名だけ（パスは list モードが見せる）。
      fontResolver.text(row.meta, base: Theme.Typography.meta)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 5) {
        ForEach(row.chips) { DispatchCleanChip(chip: $0) }
      }
      .layoutPriority(2)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    // カーソル行は行とサブラインを 1 枚の塗りに見せる（角丸を上下で分ける）。
    .background(CleanRowShape(topOnly: expanded).fill(cursor ? Color.theme.selectionFill : .clear))
    .opacity(inUse ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture { if !inUse { model.toggle(at: row.id) } }
  }

  /// ブランチの扱いを文字で選ぶサブライン。**チェックした確認行**にだけ開く。
  private var subline: some View {
    HStack(spacing: Theme.Space.step) {
      Text(l10n.format(.dispatchCleanBranchLabel, row.branch ?? ""))
        .lineLimit(1)
        .truncationMode(.tail)
      segment(.dispatchCleanBranchKeep, choice: .keep)
      segment(.dispatchCleanBranchDelete, choice: .delete)
      if !row.lossNotes.isEmpty {
        Text(l10n.format(.dispatchCleanLossNote, lossNote))
          .foregroundStyle(Color.theme.stateWaiting)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    .padding(.top, Theme.Space.hair)
    .padding(.leading, 31)
    .padding(.trailing, 10)
    .padding(.bottom, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CleanRowShape(bottomOnly: true).fill(cursor ? Color.theme.selectionFill : .clear))
  }

  private var lossNote: String {
    row.lossNotes.map { DispatchCleanChip.text($0, l10n) }.joined(separator: " · ")
  }

  /// `残す` / `削除` の 2 値。**非選択だけが線を持つが、枠の分だけ高さが動かないよう選択側にも
  /// 透明の線を敷く。** タップは行クリックと同じくカーソルもその行へ移す。
  private func segment(_ key: L10nKey, choice: CleanBranchChoice) -> some View {
    let active = model.branchChoice(of: row) == choice
    return Text(l10n.string(key))
      .foregroundStyle(active ? Color.theme.accentBright : Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 10)
      .padding(.vertical, Theme.Space.hair)
      .background(
        Capsule().fill(active ? Color.theme.accentPrimary.opacity(0.16) : .clear)
      )
      .overlay(
        Capsule().strokeBorder(
          active ? .clear : Color.theme.borderInk.opacity(0.2), lineWidth: Theme.Stroke.hairline)
      )
      .contentShape(Capsule())
      .onTapGesture { model.chooseBranch(choice, at: row.id) }
  }
}

/// 削除中・一部失敗の 1 行。**行頭のチェックがそのまま進捗になり**、レイアウトは選択画面と同一。
struct DispatchCleanRunRow: View {
  let request: CleanDeleteRequest
  let state: CleanRunState
  /// 一部失敗画面で `o` / `⏎` の対象になっている失敗行か。
  let cursor: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  private var failure: CleanFailure? {
    if case .failed(let failure) = state { return failure }
    return nil
  }
  private var isRunning: Bool { state == .running }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      main
      if failure != nil { subline }
    }
    .id(request.path)
  }

  private var main: some View {
    HStack(spacing: Theme.Space.step) {
      glyph
      fontResolver.text(
        (request.path as NSString).lastPathComponent, base: Theme.Typography.workspaceName
      )
      .font(Font.theme.workspaceName)
      .foregroundStyle(
        failure != nil || isRunning ? Color.theme.textPrimary : Color.theme.textSecondary
      )
      .lineLimit(1)
      .truncationMode(.tail)
      .layoutPriority(1)
      // meta 列が進捗のメッセージになる（選択画面のブランチ名と同じ位置・同じ字）。
      Text(message)
        .font(Font.theme.meta)
        .foregroundStyle(failure != nil ? Color.theme.danger : Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CleanRowShape(topOnly: failure != nil).fill(rowFill))
    .opacity(isSpent ? 0.5 : 1)
  }

  /// まだ撃たれていない行（待機・中断で未実行）は減光する。
  private var isSpent: Bool { state == .pending || state == .skipped }

  private var rowFill: Color {
    if failure != nil { return Color.theme.tintRed }
    return isRunning ? Color.theme.selectionFill : .clear
  }

  /// 生ログと対処（同じ赤帯を下へ続ける）。
  private var subline: some View {
    HStack(spacing: Theme.Space.beat) {
      if let log = failure?.log, !log.isEmpty {
        Text(log)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
      chip(.dispatchCleanRetry, filled: true)
      // worktree がもう無い行（ブランチ削除だけが落ちた）には開く先が無い。
      if failure?.step != .branch { chip(.dispatchCleanOpenTab, filled: false) }
    }
    .font(Font.theme.meta)
    .padding(.top, Theme.Space.hair)
    .padding(.leading, 31)
    .padding(.trailing, 10)
    .padding(.bottom, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CleanRowShape(bottomOnly: true).fill(Color.theme.tintRed))
  }

  private func chip(_ key: L10nKey, filled: Bool) -> some View {
    Text(l10n.string(key))
      .foregroundStyle(filled ? Color.theme.accentBright : Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 10)
      .padding(.vertical, Theme.Space.hair)
      .background(Capsule().fill(filled ? Color.theme.accentPrimary.opacity(0.16) : .clear))
      .overlay(
        Capsule().strokeBorder(
          filled ? .clear : Color.theme.borderInk.opacity(0.2), lineWidth: Theme.Stroke.hairline)
      )
      .opacity(cursor ? 1 : Theme.Opacity.disabled)
  }

  /// 行頭 13px の枠に、進捗をそのまま描く。待機は**選んだときのチェックがそのまま残る**。
  @ViewBuilder private var glyph: some View {
    switch state {
    case .done:
      Text("✓")
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.stateDone)
        .frame(width: 13)
    case .failed:
      Text("✕")
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.danger)
        .frame(width: 13)
    case .running:
      StatusGlyphView(kind: .working, size: 10).frame(width: 13)
    case .pending, .skipped:
      CleanCheckbox(isOn: true)
    }
  }

  private var message: String {
    switch state {
    case .pending:
      return l10n.string(
        request.deleteBranch && request.branch != nil
          ? .dispatchCleanRowPendingWithBranch : .dispatchCleanRowPending)
    case .skipped:
      return l10n.string(.dispatchCleanRowSkipped)
    case .running:
      return l10n.string(.dispatchCleanRowRunning)
    case .done(let branch, let pruned):
      if pruned { return l10n.string(.dispatchCleanRowPruned) }
      guard let branch else { return l10n.string(.dispatchCleanRowRemoved) }
      return l10n.format(.dispatchCleanRowRemovedWithBranch, branch)
    case .failed(let failure):
      switch failure.step {
      case .dirty: return l10n.string(.dispatchCleanFailedDirty)
      case .operationInProgress: return l10n.string(.dispatchCleanFailedOperation)
      case .worktree: return l10n.string(.dispatchCleanFailedWorktree)
      case .branch: return l10n.string(.dispatchCleanFailedBranch)
      }
    }
  }
}

/// 行頭 13×13 のチェックボックス。選択画面と削除中の待機行が共有する。
struct CleanCheckbox: View {
  let isOn: Bool

  var body: some View {
    if isOn {
      RoundedRectangle(cornerRadius: 3.5)
        .fill(Color.theme.accentPrimary)
        .frame(width: 13, height: 13)
        .overlay(
          Text("✓")
            .font(Font.theme.paneSegment)
            .foregroundStyle(Color.theme.accentCheckStroke))
    } else {
      RoundedRectangle(cornerRadius: 3.5)
        .strokeBorder(Color.theme.borderInk.opacity(0.35), lineWidth: Theme.Stroke.hairline)
        .frame(width: 13, height: 13)
    }
  }
}

/// 行の器。サブラインが続くときだけ角丸を上下で分け、行とサブラインを 1 枚の塗りに見せる。
struct CleanRowShape: Shape {
  var topOnly = false
  var bottomOnly = false

  func path(in rect: CGRect) -> Path {
    let radius = Theme.Radius.row
    return UnevenRoundedRectangle(
      topLeadingRadius: bottomOnly ? 0 : radius,
      bottomLeadingRadius: topOnly ? 0 : radius,
      bottomTrailingRadius: topOnly ? 0 : radius,
      topTrailingRadius: bottomOnly ? 0 : radius
    ).path(in: rect)
  }
}

/// clean 行の語彙 1 つ。**色はトーンからの写像 1 本だけを通る**——語彙が増えても色の付け方が分岐せず、
/// 塗りのあるピルと塗らない素文字の別も語彙自身（`isPill`）が持つ。
/// **git / gh の語（`[gone]` / `locked` / `PR #N merged` / `merged → <既定>` / `remote +N` /
/// `main worktree` / `clean · +0`）は L10n しない**——訳すと出力と対応が取れなくなる技術語。
struct DispatchCleanChip: View {
  let chip: CleanChip
  @Environment(\.localization) private var l10n

  var body: some View {
    if chip.isPill {
      Text(Self.text(chip, l10n))
        .font(Font.theme.sectionLabel)
        .foregroundStyle(Self.color(chip.tone))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Capsule().fill(Self.fill(chip.tone)))
    } else {
      Text(Self.text(chip, l10n))
        .font(Font.theme.sectionLabel)
        .foregroundStyle(Self.color(chip.tone))
        .lineLimit(1)
    }
  }

  /// トーン → 文字色。塗りのない素文字はこれだけを使う。
  static func color(_ tone: CleanTone) -> Color {
    switch tone {
    case .loss: return Color.theme.stateWaiting
    case .safe: return Color.theme.diffAdded
    case .neutral: return Color.theme.textMuted
    case .danger: return Color.theme.danger
    case .status: return Color.theme.stateWorking
    }
  }

  /// トーン → ピルの地。
  static func fill(_ tone: CleanTone) -> Color {
    switch tone {
    case .loss: return Color.theme.tintWaiting
    case .safe: return Color.theme.tintDiffAdded
    case .neutral: return Color.theme.plainPillFill
    case .danger: return Color.theme.tintRed
    case .status: return .clear
    }
  }

  static func text(_ chip: CleanChip, _ l10n: LocalizationStore) -> String {
    switch chip {
    case .cleanNote: return "clean · +0"
    case .uncommitted(let n):
      return l10n.plural(
        n, one: .dispatchCleanUncommittedOne, other: .dispatchCleanUncommittedOther)
    case .untracked(let n):
      return l10n.plural(n, one: .dispatchCleanUntrackedOne, other: .dispatchCleanUntrackedOther)
    case .inProgress(let operation):
      return l10n.format(.dispatchCleanInProgress, operation.name)
    case .prunable: return l10n.string(.dispatchCleanPrunable)
    case .mergedPR(let number): return "PR #\(number) merged"
    case .mergedIntoDefault(let branch): return "merged → \(branch)"
    case .remoteSynced: return l10n.string(.dispatchCleanRemoteSynced)
    case .remoteAhead(let n): return "remote +\(n)"
    case .unpushed: return l10n.string(.dispatchCleanUnpushed)
    case .openPR(let number): return "PR #\(number) open"
    case .gone: return "[gone]"
    case .ownCommits(let n):
      return l10n.plural(n, one: .dispatchCleanOwnCommitsOne, other: .dispatchCleanOwnCommitsOther)
    case .agentWorking: return l10n.string(.dispatchCleanAgentWorking)
    case .agentWaiting: return l10n.string(.dispatchCleanAgentWaiting)
    case .paneOpen: return l10n.string(.dispatchCleanPaneOpen)
    case .locked: return "locked"
    case .mainWorktree: return "main worktree"
    case .branchAlsoDeleted: return l10n.string(.dispatchCleanBranchAlsoDeleted)
    }
  }
}
