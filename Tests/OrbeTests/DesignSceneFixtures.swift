import SwiftUI

@testable import Orbe

/// design 正典 の各シーンと同データの突合用 fixture（gallery が PNG に描き、見本と突き合わせる）。
/// 値の出所は design 正典のモックデータ。
@MainActor
enum DesignSceneFixtures {

  /// WorkspaceSwitcher シーンの PaletteModel。
  static func workspaceModel() -> PaletteModel {
    let model = PaletteModel()
    model.fieldVisible = true
    model.query = "orb"
    model.scrimStrength = .normal
    model.hint = "↵ 切替/作成   → 詳細   esc 閉じる"
    func row(
      _ name: String, _ rollup: [(state: String, count: Int)], _ path: String
    ) -> PaletteModel.RowItem {
      PaletteModel.RowItem(
        label: name,
        customContent: AnyView(WorkspaceSwitcherRow(name: name, rollup: rollup, path: path)))
    }
    model.rows = [
      row("orbe-core", [("working", 3), ("waiting", 1), ("done", 5)], "~/dev/orbe"),
      row("ghostty-fork", [("working", 1), ("idle", 1)], "~/dev/ghostty"),
      row("api-gateway", [("working", 2), ("done", 3)], "~/work/api-gw"),
      row("notes", [("idle", 1)], "~/notes"),
      row("api-docs", [("waiting", 1), ("done", 2)], "~/work/api-docs"),
      // 一覧末尾に常設の作成導線行（破線罫線・accent 文字・右端 ⌘N バッジ）。
      .init(label: "＋ 新規ワークスペース — パスから作成", trailingBadge: "⌘N", createStyle: true),
    ]
    model.selected = 0
    return model
  }

  /// Dispatch シーンの DispatchPaletteModel（実データ形の決定的サンプル・原典 Dispatch 対応）。
  /// live git/gh は叩かず `DispatchSectionBuilder` に mock 入力を通す。
  static func dispatchModel() -> DispatchPaletteModel {
    dispatchModel(from: .designSample)
  }

  /// worktree 作成中（prepareDirectory 待機）。フッターにスピナ＋「作成中…」を出し入力を受け付けない。
  static func dispatchPreparingModel() -> DispatchPaletteModel {
    let model = dispatchModel(from: .designSample)
    model.isPreparing = true
    return model
  }

  /// 初回ロード中（最初の rebuild 前）のスケルトン表示（hasLoadedOnce=false・sections 空）。
  static func dispatchSkeletonModel() -> DispatchPaletteModel {
    let model = DispatchPaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    return model
  }

  /// gh 到着前のプログレッシブ表示（Issues/PR がローディング行）。
  static func dispatchLoadingModel() -> DispatchPaletteModel {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.issuesLoading = true
    input.pullRequestsLoading = true
    return dispatchModel(from: input)
  }

  /// gh 未導入のフォールバック（Issues に誘導情報行 1 本・PR 非表示）。
  static func dispatchGhMissingModel() -> DispatchPaletteModel {
    var input = DispatchSectionBuilder.Input.designSample
    input.issues = []
    input.pullRequests = []
    input.githubState = .ghMissing
    let model = dispatchModel(from: input)
    model.githubState = .ghMissing
    return model
  }

  /// 絞り込み中（`feat` で横断フィルタ・空セクションが消える）。
  static func dispatchFilteredModel() -> DispatchPaletteModel {
    let model = dispatchModel(from: .designSample)
    model.query = "feat"
    model.onQueryChanged()
    return model
  }

  /// 多件数（cap 380 を超え内部スクロールへ回る回帰検証。長い branch 名・PR で狭幅も試す）。
  static func dispatchManyModel() -> DispatchPaletteModel {
    let home = NSHomeDirectory()
    var input = DispatchSectionBuilder.Input()
    input.currentWorktree = "\(home)/wt/feature-0"
    input.worktrees = (0..<6).map {
      GitWorktree(
        path: "\(home)/wt/feature-\($0)", branch: "feature/very-long-branch-name-\($0)",
        head: "h\($0)", isMain: $0 == 0)
    }
    input.localBranches = (0..<10).map {
      GitBranch(
        name: "topic/some-fairly-long-local-branch-\($0)", relativeDate: "\($0)d前",
        worktreePath: nil, upstream: nil)
    }
    input.remoteBranches = (0..<4).map {
      GitBranch(
        name: "origin/release/candidate-\($0)", relativeDate: "user\($0) · \($0)h前",
        worktreePath: nil, upstream: nil)
    }
    input.issues = (0..<12).map {
      GitHubIssue(number: 200 + $0, title: "実データ由来の長めの issue タイトル その\($0)")
    }
    input.pullRequests = (0..<6).map {
      GitHubPullRequest(
        number: 300 + $0, title: "feat: それなりに長い PR のタイトル \($0)",
        headRefName: "feature/very-long-branch-name-\($0)",
        reviewDecision: $0.isMultiple(of: 2) ? "REVIEW_REQUIRED" : "APPROVED",
        isCrossRepository: false)
    }
    input.githubState = .ready
    let model = dispatchModel(from: input)
    model.selected = model.items.count - 1  // 末尾選択（scroll-to-end 到達の確認）
    return model
  }

  /// 分冊（+Clean）からも呼ぶ組み立て口。
  static func dispatchModel(from input: DispatchSectionBuilder.Input)
    -> DispatchPaletteModel
  {
    let model = DispatchPaletteModel()
    model.setTargets(
      agents: [AgentCLI(command: "claude", path: "/usr/bin/claude")], defaultCommand: "claude")
    model.sections = DispatchSectionBuilder.build(input)
    model.hasLoadedOnce = true
    model.clampSelection()
    return model
  }

  /// Autocomplete シーンの候補モデル（`git ch` の補完）。
  static func completionModel() -> CompletionListModel {
    let model = CompletionListModel()
    model.query = "ch"
    model.choices = CompletionList.displayOrdered([
      CompletionChoice(value: "checkout", description: "", insertValue: nil, type: "subcommand"),
      CompletionChoice(value: "cherry-pick", description: "", insertValue: nil, type: "subcommand"),
      CompletionChoice(value: "cherry", description: "", insertValue: nil, type: "subcommand"),
      CompletionChoice(value: "switch", description: "", insertValue: nil, type: "subcommand"),
    ])
    model.selected = 0
    return model
  }

  /// Autocomplete シーンのサイドカード。
  static func completionSideCard() -> CompletionSideCard {
    CompletionSideCard(
      name: "git checkout <branch>", kind: .subcommand,
      description: "ブランチを切り替える。最近のブランチ:")
  }

  // MARK: - Update（見本 UpdateCheckDoc 2a–2d 同データ。Sparkle 実体なしで各状態を注入する）

  /// 見本のリリースノート（2b の 3 分類・ユーザー語）。appcast description と同じ Markdown 形。
  /// 箇条書きでない段落を 2 通り置いてある——本文として読ませる注意書きと、
  /// 末尾の出典段落（GPL §6 表記）。段落の描かれ方をここで見る。
  /// 「改善」だけ項目を 2 つ持ち、うち 1 つは折り返す長さ——項目間の間隔と、
  /// 折り返した行が `＋` の下へ回り込まず本文の左端で揃うことをここで見る。
  static let updateSampleNotes = """
    ### 新機能
    - タブからそのまま使える `orbe` コマンドを同梱しました
    ### 改善
    - タブ補完の候補表示が速くなりました
    - ワークスペースの切り替えでエージェントのタブ順が保たれるようになり、復帰したときに前と同じ並びで再開できます
    ### 修正
    - エージェント実行中にタブ表示が止まる問題を修正しました

    v0.1.0 をお使いの方へ: 自動更新はこの版から有効になります。今回だけ手動でダウンロードして入れ替えてください。

    ソース: https://github.com/nakashima-takeo/orbe/tree/v0.2.0
    """

  /// 項目の多いノート（3 分類・11 項目）。シートが窓に収まりボタンが見えること、
  /// 溢れた分がノート部の内部スクロールへ回ることをここで見る。
  static let updateLongSampleNotes = """
    ### 新機能
    - タブからそのまま使える `orbe` コマンドを同梱しました
    - ワークスペースを跨いでタブを検索できるようになりました
    - エージェントの状態をステータス行にまとめて出すようにしました
    - 差分パネルからコミットの詳細を開けるようになりました
    ### 改善
    - タブ補完の候補表示が速くなりました
    - ワークスペースの切り替えでエージェントのタブ順が保たれるようになり、復帰したときに前と同じ並びで再開できます
    - パレットの絞り込みが日本語入力中でも追従するようになりました
    - 起動直後のフォント読み込みを速くしました
    ### 修正
    - エージェント実行中にタブ表示が止まる問題を修正しました
    - ワークツリーの削除に失敗したときに孤児が残る問題を修正しました
    - 設定を閉じたあとフォーカスが戻らない問題を修正しました

    ソース: https://github.com/nakashima-takeo/orbe/tree/v0.2.0
    """

  /// 「修正」だけのノート。分類が並び順ではなく見出しの語で決まること（先頭でも青＋`＋`にならない）を見る。
  static let updateFixOnlyNotes = """
    ### 修正
    - エージェント実行中にタブ表示が止まる問題を修正しました
    - 設定を閉じたあとフォーカスが戻らない問題を修正しました
    """

  /// 規約外の見出しと見出し無しを含むノート。中立の `•` が最も細いマーカーなので、
  /// 分類が変わっても項目本文の左端が動かないこと（マーカー列が固定幅であること）をここで見る。
  static let updateNeutralNotes = """
    - 見出しより前の項目
    ### 既知の問題
    - 全画面の切り替え中にタブ行が一瞬ちらつきます
    ### 修正
    - エージェント実行中にタブ表示が止まる問題を修正しました
    """

  private static func baseUpdateState() -> UpdateState {
    let state = UpdateState(currentVersion: "0.1.0")
    state.seedLastCheck(Date(timeIntervalSinceNow: -300))
    return state
  }

  /// 適用待ち（2a トースト・2b シート・2c 状態カードの正）。v0.2.0 / 2026-07-13 / 13 MB。
  static func updateReadyState(notes: String = updateSampleNotes) -> UpdateState {
    let state = baseUpdateState()
    state.markReady(
      UpdateState.ReadyInfo(
        version: "0.2.0", notes: notes,
        date: DateComponents(
          calendar: .init(identifier: .gregorian), year: 2026, month: 7, day: 13
        ).date,
        size: 13_000_000))
    return state
  }

  static func updateCheckingState() -> UpdateState {
    let state = baseUpdateState()
    state.beginCheck()
    return state
  }

  /// DL中 64%（見本 2d の `8.3 MB / 13 MB` mono 表記）。DL 中は Sparkle が確認を受け付けないため
  /// 確認不可も張る（「今すぐ確認」行の減光と、理由を語るカードが同時に読めるか見る）。
  static func updateDownloadingState() -> UpdateState {
    let state = baseUpdateState()
    state.beginDownload(version: "0.2.0")  // 実フローと同順（found→DL 開始、ready はまだ立たない）
    state.setExpectedLength(13_000_000)
    state.receiveData(length: 8_300_000)
    state.setCheckAvailability(.busy)
    return state
  }

  /// 適用待ち＋確認不可（staged 済みに再確認は無意味）。「今すぐ確認」行の減光を見る。
  static func updateReadyBusyState() -> UpdateState {
    let state = updateReadyState()
    state.setCheckAvailability(.busy)
    return state
  }

  /// 背景の定期確認が走っている最中（phase は idle のまま確認不可）。状態カードは「まだ確認して
  /// いません」に留まり、進行中の確認は「今すぐ確認」行のスピナー＋「確認中…」だけが語る。
  static func updateBackgroundCheckingState() -> UpdateState {
    let state = baseUpdateState()
    state.setCheckAvailability(.busy)
    return state
  }

  /// updater が動いていないビルド（起動ゲートを通らない dev ビルド）。状態カードは「このビルドでは
  /// 更新を確認しません」（右端は空）で、確認は走らないので「今すぐ確認」行は「確認中…」を名乗らず
  /// 減光だけになる——`updateBackgroundCheckingState` との差がここで出る。
  /// 確認が走らない＝最終確認時刻を持たないため、情報行は「最終確認: —」になる。
  static func updateUnavailableState() -> UpdateState {
    let state = UpdateState(currentVersion: "0.1.0")
    state.setCheckAvailability(.unavailable)
    return state
  }

  static func updateUpToDateState() -> UpdateState {
    let state = baseUpdateState()
    state.markUpToDate()
    return state
  }

  static func updateFailedState() -> UpdateState {
    let state = baseUpdateState()
    state.fail(message: "接続に失敗しました")
    return state
  }

  /// 起動直後（確認は走れるが、まだ一度も結果を得ていない）。
  /// 「まだ確認していません」＋「最終確認: —」を見る。
  static func updateNeverCheckedState() -> UpdateState {
    UpdateState(currentVersion: "0.1.0")
  }

  /// 設定パレットをアップデートセクションへ潜らせたモデル（2c/2d。gallery/flow が状態カードを撮る）。
  /// - Parameter selectCheckNow: 末尾の「今すぐ確認」行を選択する。行が器の高さ上限を超える状態
  ///   （適用待ち）で、その行が見えているスクロール位置＝押そうとしている状況を撮るために使う。
  static func updateSettingsModel(_ state: UpdateState, selectCheckNow: Bool = false)
    -> SettingsPaletteModel
  {
    let model = SettingsPaletteModel(
      values: ScopedSettingsValues(global: SettingsLayer(), override: SettingsLayer()),
      fontNames: [], agents: ["claude"], localization: LocalizationStore(language: .ja),
      update: state)
    model.drillIntoUpdate()
    if selectCheckNow { model.render.selected = model.render.rows.count - 1 }
    return model
  }
}
