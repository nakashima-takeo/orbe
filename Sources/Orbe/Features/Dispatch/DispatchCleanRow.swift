import SwiftUI

// clean の 1 行。**3 画面は同じ行の別の時点**なので、行頭のグリフと meta 列だけが入れ替わり、
// 器（padding 5×10・radius 8・gap 8・13px の行頭・末尾省略の meta）は共通の契約として保つ。

/// トーン → 色の唯一の写像。**語彙のピルも失敗行の赤もここだけを通る**——同じ意味の色に到達する経路を
/// 2 本持つと、写像を直した日に片方が取り残される。
extension CleanTone {
  /// 文字色。塗りのない素文字はこれだけを使う。
  var foreground: Color {
    switch self {
    case .loss: return Color.theme.stateWaiting
    case .safe: return Color.theme.diffAdded
    case .neutral: return Color.theme.textMuted
    case .danger: return Color.theme.danger
    case .status: return Color.theme.stateWorking
    }
  }

  /// 塗り（ピルの地・失敗行の帯）。
  var fill: Color {
    switch self {
    case .loss: return Color.theme.tintWaiting
    case .safe: return Color.theme.tintDiffAdded
    case .neutral: return Color.theme.plainPillFill
    case .danger: return Color.theme.tintRed
    case .status: return .clear
    }
  }
}

/// 選択画面の 1 行（＋チェックすると開くサブライン）。
/// **背景ハイライトはカーソル行だけ**——チェック状態は ✓ ボックスの塗りだけが示す（背景で二重に示さない）。
struct DispatchCleanRow: View {
  @Bindable var model: DispatchCleanModel
  let row: CleanRow
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  private var inUse: Bool { row.group == .inUse }
  /// まだ必要な事実が揃っていない行。**回転グリフが「まだ動いている」を語り**、減光しない
  /// ——静止＋減光の `inUse`（もう動かない／削除できない）と、動きと減光の 2 軸で分かれる。
  private var pending: Bool { !inUse && !row.isReady }
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
      } else if pending {
        // 一覧のローディング行と同じ部品・同じ意味（まだ動いている）。
        StatusGlyphView(kind: .working, size: 10).frame(width: 13, height: 13)
      } else {
        CleanCheckbox(isOn: model.isChecked(row))
      }
      // 縮む順は meta → 右クラスタ → 名前（優先度 0 < 1 < 2）。**名前は行の識別子なので最後まで
      // 読める幅を保つ**——名前が潰れた行は、どの worktree の話なのかが読めず用をなさない。
      // どれも 1 行で末尾省略し、折り返さない。行の最小幅を提案幅より小さく保てないと、
      // 器のカードが窓を超えて広がる。
      fontResolver.text(row.name, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(cursor ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(2)
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
      .layoutPriority(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    // カーソル行は行とサブラインを 1 枚の塗りに見せる（角丸を上下で分ける）。
    .background(CleanRowShape(topOnly: expanded).fill(cursor ? Color.theme.selectionFill : .clear))
    .opacity(inUse ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture { if !inUse && !pending { model.toggle(at: row.id) } }
  }

  /// **この行の詳細**。チェックした確認行にだけ開く。ブランチの扱いを選ぶセグメントは中身の 1 つで、
  /// detached（ブランチが無い）行では損失の内訳だけが並ぶ——rebase 停止中の worktree は必ず
  /// detached なので、ここを閉じると失う untracked / 未コミットが画面から落ちる。
  /// 右クラスタの 2 枚に載らなかったピルもここへ回る（見た目は右クラスタと同じまま）。
  private var subline: some View {
    HStack(spacing: Theme.Space.step) {
      if let branch = row.branch {
        Text(l10n.format(.dispatchCleanBranchLabel, branch))
          .lineLimit(1)
          .truncationMode(.tail)
        segment(.dispatchCleanBranchKeep, choice: .keep)
        segment(.dispatchCleanBranchDelete, choice: .delete)
      }
      if !row.lossNotes.isEmpty {
        Text(l10n.format(.dispatchCleanLossNote, lossNote))
          .foregroundStyle(Color.theme.stateWaiting)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      // 溢れたピルは事実のまま出す。損失の内訳と混ぜて `〜も消えます` に飲み込ませない。
      ForEach(row.overflowNotes) { DispatchCleanChip(chip: $0) }
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

  /// `残す` / `削除` の 2 値。タップは行クリックと同じくカーソルもその行へ移す。
  private func segment(_ key: L10nKey, choice: CleanBranchChoice) -> some View {
    CleanCapsule(text: l10n.string(key), active: model.branchChoice(of: row) == choice)
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
  /// 対処の案内（`⏎ 再試行` / `o タブで開く`）を出すか。**削除中は出さない**——駆動中は ⏎ も `o` も
  /// 効かないので、効かない案内を残さない。
  let showsActions: Bool
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
        .foregroundStyle(failure != nil ? CleanTone.danger.foreground : Color.theme.textMuted)
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
    if failure != nil { return CleanTone.danger.fill }
    return isRunning ? Color.theme.selectionFill : .clear
  }

  /// 生ログと対処（同じ赤帯を下へ続ける）。
  private var subline: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      if let log = failure?.log, !log.isEmpty {
        Text(log)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
      if showsActions {
        chip(.dispatchCleanRetry, filled: true)
        // worktree がもう無い行（ブランチ削除だけが落ちた）には開く先が無い。
        if failure?.step != .branch { chip(.dispatchCleanOpenTab, filled: false) }
      }
    }
    .font(Font.theme.meta)
    .padding(.top, Theme.Space.hair)
    .padding(.leading, 31)
    .padding(.trailing, 10)
    .padding(.bottom, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CleanRowShape(bottomOnly: true).fill(CleanTone.danger.fill))
  }

  private func chip(_ key: L10nKey, filled: Bool) -> some View {
    CleanCapsule(text: l10n.string(key), active: filled)
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
        .foregroundStyle(CleanTone.danger.foreground)
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
      guard let branch else {
        return l10n.string(pruned ? .dispatchCleanRowPruned : .dispatchCleanRowRemoved)
      }
      // ブランチも消したときは必ずその名前を出す。実体が無かった行でも、消したものを記録から落とさない。
      return l10n.format(
        pruned ? .dispatchCleanRowPrunedWithBranch : .dispatchCleanRowRemovedWithBranch, branch)
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

/// サブラインのカプセル。**`残す` / `削除` のセグメントと失敗行の対処チップが共有する装飾**で、
/// 強調側は塗り・非強調側は線。枠の分で高さが動かないよう、塗り側にも透明の線を敷く。
struct CleanCapsule: View {
  let text: String
  let active: Bool

  var body: some View {
    Text(text)
      .foregroundStyle(active ? Color.theme.accentBright : Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 10)
      .padding(.vertical, Theme.Space.hair)
      .background(Capsule().fill(active ? Color.theme.accentPrimary.opacity(0.16) : .clear))
      .overlay(
        Capsule().strokeBorder(
          active ? .clear : Color.theme.borderInk.opacity(0.2), lineWidth: Theme.Stroke.hairline)
      )
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
