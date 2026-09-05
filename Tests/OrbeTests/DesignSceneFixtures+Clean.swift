import SwiftUI

@testable import Orbe

/// clean の 3 画面（選択 / 削除中 / 一部失敗）の fixture。**本物の中身で撮る**——生の
/// `DispatchCleanFacts` を分類の純粋関数へ通して行を導き、画面の遷移も本物のモデル操作で作る
/// （分類結果も進捗も手で置かない）。
@MainActor
extension DesignSceneFixtures {

  /// list モードで `clean` 行を選んだ状態（フッターが注記だけになり、キーヒントが消える）。
  static func dispatchCleanRowModel() -> DispatchPaletteModel {
    let model = dispatchModel(from: .designSample)
    if let index = model.items.firstIndex(where: { $0.action == .clean }) { model.selected = index }
    return model
  }

  /// clean 画面 1（選択）。安全群が全チェック済みで開いた既定状態。
  static func dispatchCleanModel() -> DispatchPaletteModel {
    let model = dispatchModel(from: .designSample)
    model.classification = cleanRows
    model.enterClean()
    return model
  }

  /// clean 画面 1 の途中経過。**一部の行がまだ確定していない**（行頭が回転グリフ・選べない）姿で、
  /// 確定済みの安全行にだけチェックが灯っている。行ごとの準備完了という状態を画像で残す
  /// ——PR の取得は head 単位に着地するので、この「まだらな途中」が実機で必ず通る時点になる。
  static func dispatchCleanPendingModel() -> DispatchPaletteModel {
    let model = dispatchModel(from: .designSample)
    // 確定させるのは 1 本目の安全行だけ。残りは PR 取得の未着地（`.pending`）のまま。
    model.classification = DispatchWorktreeClassifier.classify(
      cleanFacts.map { $0.path.hasSuffix("dispatch-delete") ? $0 : $0.with(openPR: .pending) })
    model.enterClean()
    return model
  }

  /// 選択 0 件（実行ボタンが 0.45 減光・ヘッダーが `0 件選択中`）。
  static func dispatchCleanEmptyModel() -> DispatchPaletteModel {
    let model = dispatchCleanModel()
    // 逆順に外すと、最後に触った行＝先頭にカーソルが残る（既定状態と同じ位置で撮る）。
    for row in model.clean.rows.reversed() where model.clean.isChecked(row) {
      model.clean.toggle(at: row.id)
    }
    return model
  }

  /// 確認行をチェックしてサブラインを開き、`削除` を選んだ姿（本物のモデル操作で作る）。
  static func dispatchCleanSublineModel() -> DispatchPaletteModel {
    let model = dispatchCleanModel()
    guard let caution = model.clean.rows.first(where: { $0.group == .caution && $0.branch != nil })
    else { return model }
    model.clean.toggle(at: caution.id)
    model.clean.chooseBranch(.delete, at: caution.id)
    return model
  }

  /// ピルが 3 枚競合する行（`rebase 進行中` × `merged → main` × `locked`）を開いた姿。
  /// loss の 2 枚（`rebase 進行中` / `locked`）がピルに残り、**上限に載らなかった `merged → main` が
  /// サブラインへ回っている**ことを画像で残す——受け皿を損失の内訳と兼ねると、ここから静かに消える。
  ///
  /// 行は**溢れの有無ではなく名前で選ぶ**。溢れが壊れた日にこのシーンが「開いていない行」へ
  /// 逃げてしまうと、画像の差分が「何かが減った」ではなく「別の画面」になって読めない。
  static func dispatchCleanOverflowModel() -> DispatchPaletteModel {
    let model = dispatchCleanModel()
    guard let locked = model.clean.rows.first(where: { $0.name == "session-restore" }) else {
      return model
    }
    model.clean.toggle(at: locked.id)
    return model
  }

  /// clean 画面 2（削除中）。✓ 2 件・スピナ 1 件・待機 1 件。件数は実行順の配列から導く。
  static func dispatchCleanDeletingModel() -> DispatchPaletteModel {
    let model = dispatchCleanRunModel()
    model.clean.markRunning(path: runPaths(model)[2])
    return model
  }

  /// clean 画面 3（一部失敗）。**成功行を消さない**まま、失敗行が赤帯・生ログ・対処を持つ。
  static func dispatchCleanFailureModel() -> DispatchPaletteModel {
    let model = dispatchCleanRunModel()
    let paths = runPaths(model)
    model.clean.markFinished(
      path: paths[2],
      outcome: .failed(
        CleanFailure(
          step: .worktree, log: "fatal: validation failed, cannot remove working tree")))
    model.clean.markFinished(path: paths[3], outcome: .succeeded(branch: "ship/…", pruned: false))
    return model
  }

  /// 削除中・一部失敗が共有する「先頭 2 件が終わっている実行」。
  private static func dispatchCleanRunModel() -> DispatchPaletteModel {
    let model = dispatchCleanSublineModel()
    model.clean.beginRun(model.clean.requests())
    let paths = runPaths(model)
    model.clean.markFinished(
      path: paths[0], outcome: .succeeded(branch: "feat/dispatch-delete", pruned: false))
    model.clean.markFinished(path: paths[1], outcome: .succeeded(branch: nil, pruned: true))
    // 残りは削除中＝待機・一部失敗＝各画面が続けて置く（同じ実行の別の時点）。
    return model
  }

  private static func runPaths(_ model: DispatchPaletteModel) -> [String] {
    model.clean.run?.requests.map(\.path) ?? []
  }

  /// clean シーンの worktree 群（design 正典 の `rows` と同じ 8 本）。3 軸それぞれの語彙が出るよう、
  /// 生の facts を分類の純粋関数へ通して導く（分類結果を手で置かない）。
  /// **語彙の網羅は `DispatchWorktreeClassifierTests` が持つ**——8 本の行にピル 2 枚上限がかかるので、
  /// gallery は「見本と同じ行が見本どおりに描けるか」だけを見る。
  private static var cleanRows: [CleanRow] { DispatchWorktreeClassifier.classify(cleanFacts) }

  /// clean シーンの worktree 群の素の事実。行はここから分類の純粋関数を通して導く。
  private static var cleanFacts: [DispatchCleanFacts] {
    let home = NSHomeDirectory()
    func path(_ name: String) -> String { "\(home)/dev/storefront-worktrees/\(name)" }
    return [
      // 軸C: agent 作業中（使用中へ移る）
      DispatchCleanFacts(
        path: path("agent-hooks"), branch: "feature/agent-hooks",
        upstream: "origin/feature/agent-hooks", track: "[gone]",
        openPR: .none, occupancy: TabOccupancy(cwd: path("agent-hooks"), agentState: "working")),
      // 軸B: PR merged（安全・ブランチも消える）
      DispatchCleanFacts(
        path: path("dispatch-delete"), branch: "feat/dispatch-delete",
        upstream: "origin/feat/dispatch-delete",
        closedPR: DispatchCleanPR(number: 142, isMerged: true, base: "main"), openPR: .none,
        status: cleanStatus,
        containment: .patchEquivalent(target: "main"), operation: .none),
      // 軸B: 独自コミット（`[gone]` に潰されずに損失を名乗る）
      DispatchCleanFacts(
        path: path("wt-path-template"), branch: "ship/…", upstream: "origin/ship/…",
        track: "[gone]", closedPR: DispatchCleanPR(number: 118, isMerged: false, base: "main"),
        openPR: .none, status: cleanStatus, containment: .unmerged(count: 6), operation: .none),
      // 軸A: 未コミット＋untracked（溢れた分はサブラインの損失内訳へ）／軸B: open PR
      DispatchCleanFacts(
        path: path("diff-panel"), branch: "fix/diff-panel", upstream: "origin/fix/diff-panel",
        openPR: .open(139), status: GitWorktreeStatusCounts(modified: 12, untracked: 3),
        containment: .patchEquivalent(target: "main"), operation: .none),
      // 軸A: rebase 進行中（status が clean でも安全群に入らない）／軸B: 未 push
      DispatchCleanFacts(
        path: path("session-restore"), branch: "feat/session-restore", lockReason: "USB",
        openPR: .none, status: cleanStatus, containment: .patchEquivalent(target: "main"),
        operation: .inProgress(.rebase)),
      // 軸A: prunable（実体が無く、ブランチには触らない）
      DispatchCleanFacts(
        path: path("render-batching"), branch: "perf/render-batching", isPrunable: true,
        upstream: "origin/perf/render-batching", track: "[gone]",
        openPR: .none, containment: .patchEquivalent(target: "main")),
      // 軸B: PR merged（2 本目の安全行）
      DispatchCleanFacts(
        path: path("tab-focus"), branch: "fix/tab-focus", upstream: "origin/fix/tab-focus",
        closedPR: DispatchCleanPR(number: 131, isMerged: true, base: "main"), openPR: .none,
        status: cleanStatus,
        containment: .patchEquivalent(target: "main"), operation: .none),
      // 軸C: main worktree
      DispatchCleanFacts(
        path: "\(home)/dev/storefront", branch: "main", isMain: true, openPR: .none),
    ]
  }

  private static let cleanStatus = GitWorktreeStatusCounts(modified: 0, untracked: 0)
}

extension DispatchCleanFacts {
  /// PR 軸だけを差し替えた事実（準備完了の有無で見え方を比べるためのテスト支援）。
  func with(openPR: CleanOpenPR) -> DispatchCleanFacts {
    DispatchCleanFacts(
      path: path, branch: branch, head: head, isMain: isMain, isPrunable: isPrunable,
      lockReason: lockReason, upstream: upstream, track: track, closedPR: closedPR,
      openPR: openPR, status: status, containment: containment, operation: operation,
      occupancy: occupancy, isProbing: isProbing)
  }
}
