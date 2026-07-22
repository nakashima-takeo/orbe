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

  private static func dispatchModel(from input: DispatchSectionBuilder.Input)
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
}
