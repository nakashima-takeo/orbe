import Foundation

/// 確認行のブランチの扱い。チェックした行の下に開くサブラインで文字選択する 2 値。
/// **「消すか」と「ブランチをどうするか」は直交した別の決定**なので 1 本の巡回に畳まない。
enum CleanBranchChoice: Equatable {
  case keep, delete
}

/// 削除 1 件の依頼。ブランチを消すかの**判断**は `DispatchCleanModel.deletesBranch(_:)` だけが持ち、
/// 実行側は渡されたとおりに実行する（判断と実行を分ける）。
struct CleanDeleteRequest: Equatable {
  let path: String
  let branch: String?
  /// 分類した時点の HEAD の oid。ブランチ削除はこの先端のときだけ通す。
  let head: String
  let deleteBranch: Bool
  /// worktree は前の試行で消えている（`.branch` で落ちた行の再試行）。**残りはブランチ削除だけ**なので、
  /// 実体の無いパスへ status を撃って「未コミットの変更がある」と嘘の理由で落ちるのを防ぐ。
  var worktreeAlreadyRemoved = false
}

/// 削除 1 行の状態。**行頭のチェックがそのままこれになる**（待機はチェック済みボックスのまま減光）。
enum CleanRunState: Equatable {
  case pending
  /// 中断で撃たれないまま終わった。**待機と違い二度と撃たれない**——中断は不可逆なので、
  /// 「まだ撃つものが残っている」と読まれないよう待機とは別の終端状態で持つ。
  case skipped
  case running
  /// 削除できた。`branch` はブランチも消したときだけ名前を持ち、`pruned` は実体の無い登録の掃除。
  case done(branch: String?, pruned: Bool)
  case failed(CleanFailure)
}

/// 削除がどこで落ちたか。meta 列の短い理由を View が言語別に引くための意味キー。
enum CleanFailureStep: Equatable {
  /// 削除の直前に叩いた status が clean でなく、撃つ前に中止した。
  case dirty
  /// 削除の直前に見た gitdir に停止中の git 操作が残っており、撃つ前に中止した。
  case operationInProgress
  /// `git worktree remove` が拒否された。
  case worktree
  /// worktree は消えたが、ブランチ削除が拒否された（先端が動いた等）。
  case branch
}

/// 失敗 1 件。`log` は行のサブラインへ出す git の生 stderr（打ち切りならその文言、
/// 撃つ前に止めた `.dirty` では空）。
struct CleanFailure: Equatable {
  let step: CleanFailureStep
  let log: String
}

/// 実行中／完了した削除。**選んだ行だけ**が実行順に並ぶ。
/// 削除中と一部失敗は同じ行集合の別の時点なので、件数はすべてここからの filter で出す
/// （リテラルの件数も、保存したフェーズも持たない）。
struct CleanRun: Equatable {
  /// 実行順（＝選択画面の行順）。再試行で「worktree は消えている」が判れば依頼が更新される。
  var requests: [CleanDeleteRequest]
  /// `requests` と同 index の状態。
  var states: [CleanRunState]

  /// 据わった（撃つべきものが残っていない）。中断は待機を `.skipped` へ落とすので、
  /// **据わりの判定はこの 1 本だけ**——「中断したか」を別に覚えて条件を分岐させない。
  var isSettled: Bool { !states.contains(.running) && !states.contains(.pending) }
}

/// clean の画面。**保存しない**——見本の「削除中と一部失敗は同じ行集合の別の時点」という構造を
/// そのまま持つため、状態から導出する。
enum CleanPhase: Equatable {
  case selecting, deleting, failed
}

/// 中断の唯一の入力。`cancel()` 後は次の 1 件を撃たない（撃った弾は追いかけない）。
final class CleanRunToken {
  private(set) var isCancelled = false
  func cancel() { isCancelled = true }
}

/// clean 画面の状態と操作の意味。**キーの意味を名前付きメソッドで持ち**、View の `.onKeyPress` は
/// 1 行のアダプタにする（このコードベースの規約。テストはモデルを直接叩く）。
/// 画面ごとの分岐も View に置かず、各メソッドが `phase` を見て自分で畳む。
///
/// 行の一覧は `enter(rows:)` で凍結する。破壊的な複数選択 UI で、カーソルの下のリストが後から届いた
/// データで組み替わることを構造で禁じるため、裏の分類更新はこの画面に届かない。
@Observable final class DispatchCleanModel {
  /// 群順（safe → caution → inUse）に並んだ凍結スナップショット。
  private(set) var rows: [CleanRow] = []
  /// `selectableRows` を数えた選択画面のカーソル。
  private(set) var cursor = 0
  /// `failedIndices` を数えた一部失敗画面のカーソル（選択画面とは巡回対象が違うので別に持つ）。
  private(set) var failureCursor = 0
  /// チェックした行 id（＝絶対パス）。
  private(set) var checked: Set<String> = []
  /// 行 id → ブランチの扱い（辞書に無い＝既定の `.keep`）。
  private(set) var branchChoice: [String: CleanBranchChoice] = [:]
  /// 実行中／完了した削除。nil なら選択画面。
  private(set) var run: CleanRun?
  /// 実行中の削除を止める札（`beginRun` / `retryRequests` が張り直す）。
  private(set) var runToken: CleanRunToken?

  /// カーソル巡回・選択の対象（inUse 行は飛ばす）。
  var selectableRows: [CleanRow] { rows.filter { $0.group != .inUse } }

  /// 画面。`run` が無ければ選択、据わっていれば一部失敗、それ以外は削除中。
  var phase: CleanPhase {
    guard let run else { return .selecting }
    return run.isSettled ? .failed : .deleting
  }

  /// 分類スナップショットで画面を開く。safe 群を全チェック・確認群は未選択・ブランチの扱いは全て
  /// `残す`・カーソルは先頭。
  func enter(rows: [CleanRow]) {
    self.rows = rows
    cursor = 0
    failureCursor = 0
    checked = Set(rows.filter { $0.group == .safe }.map(\.id))
    branchChoice = [:]
    run = nil
    runToken = nil
  }

  // MARK: - 選択（2 軸）

  func isChecked(_ row: CleanRow) -> Bool { checked.contains(row.id) }

  /// この行のブランチの扱い（辞書に無ければ既定の `.keep`）。
  func branchChoice(of row: CleanRow) -> CleanBranchChoice { branchChoice[row.id] ?? .keep }

  /// サブライン（この行の詳細）が開いているか。**確認行をチェックした瞬間**に開く。
  /// 開ける条件は行自身が持つ（`canExpandSubline`）——受け皿に積んだ語が画面へ出る唯一の経路なので、
  /// 「積める行」と「開ける行」を 1 つの述語に揃える。
  func isExpanded(_ row: CleanRow) -> Bool {
    row.canExpandSubline && isChecked(row)
  }

  /// ブランチの扱いを選べるか（詳細の中身の 1 つ。detached には選ぶものが無い）。
  func canChooseBranch(_ row: CleanRow) -> Bool {
    isExpanded(row) && row.branch != nil
  }

  /// カーソル行（範囲外なら nil）。
  var cursorRow: CleanRow? {
    let rows = selectableRows
    return rows.indices.contains(cursor) ? rows[cursor] : nil
  }

  /// 選択画面は選択可能行を、一部失敗画面は**失敗行だけ**を wrap 巡回する。削除中は動かさない。
  func move(_ direction: Int) {
    switch phase {
    case .selecting:
      let count = selectableRows.count
      guard count > 0 else { return }
      cursor = (cursor + direction + count) % count
    case .failed:
      let count = failedIndices.count
      guard count > 0 else { return }
      failureCursor = (failureCursor + direction + count) % count
    case .deleting:
      break
    }
  }

  /// カーソル行のチェックを反転する。
  func toggleAtCursor() {
    guard phase == .selecting, let row = cursorRow else { return }
    setChecked(!checked.contains(row.id), at: row.id)
  }

  /// 指定行のチェックを反転し、**カーソルもその行へ移す**
  /// （ハイライト＝カーソル＝次に space/⏎ が効く行、を崩さない）。
  func toggle(at rowID: String) {
    guard phase == .selecting, let index = selectableRows.firstIndex(where: { $0.id == rowID })
    else { return }
    cursor = index
    setChecked(!checked.contains(rowID), at: rowID)
  }

  /// カーソル行のブランチの扱いを決める。**サブラインが開いている行だけで効く**
  /// （開いていない行に不可視の状態を持たせない）。
  func chooseBranch(_ choice: CleanBranchChoice) {
    guard phase == .selecting, let row = cursorRow, canChooseBranch(row) else { return }
    branchChoice[row.id] = choice
  }

  /// 指定行のブランチの扱いを決め、カーソルもその行へ移す（セグメントのタップ経路）。
  func chooseBranch(_ choice: CleanBranchChoice, at rowID: String) {
    guard phase == .selecting, let index = selectableRows.firstIndex(where: { $0.id == rowID })
    else { return }
    cursor = index
    guard canChooseBranch(selectableRows[index]) else { return }
    branchChoice[rowID] = choice
  }

  /// safe 群を全選択する（**トグルではない・追加のみ**。確認行のブランチの扱いにも触らない）。
  func selectAllSafe() {
    guard phase == .selecting else { return }
    for row in rows where row.group == .safe { checked.insert(row.id) }
  }

  var selectedCount: Int { checked.count }

  var canExecute: Bool { selectedCount > 0 && phase == .selecting }

  /// この行でローカルブランチも消すか。
  /// safe 行は**行内注記が出る行だけ**が無条件に消す——safe 群は「消してもコミットが世界に残る」
  /// （`refs/remotes/origin/*` からの到達性、または既定ブランチへの patch 等価）を必ず通っており、
  /// 消して失うものが無いことが確認済みだから。実体の無い prunable 行は消えるのが
  /// 登録だけなのでブランチに触らない。確認行はサブラインで選んだ 2 値がそのまま決める。
  func deletesBranch(_ row: CleanRow) -> Bool {
    switch row.group {
    case .safe: return row.deletesBranchImplicitly
    case .caution: return branchChoice(of: row) == .delete
    case .inUse: return false
    }
  }

  /// 実行の依頼一覧（チェックした行だけ・スナップショットの並び順）。
  func requests() -> [CleanDeleteRequest] {
    rows.filter { checked.contains($0.id) }.map {
      CleanDeleteRequest(
        path: $0.id, branch: $0.branch, head: $0.head, deleteBranch: deletesBranch($0))
    }
  }

  // MARK: - 実行（削除中・一部失敗）

  /// 選択画面 → 削除中。全行が待機で並び、中断の札を新しく張る。
  @discardableResult
  func beginRun(_ requests: [CleanDeleteRequest]) -> CleanRunToken {
    let token = CleanRunToken()
    run = CleanRun(requests: requests, states: Array(repeating: .pending, count: requests.count))
    runToken = token
    failureCursor = 0
    return token
  }

  func markRunning(path: String) { setState(.running, at: path) }

  func markFinished(path: String, outcome: CleanOutcome) {
    switch outcome {
    case .succeeded(let branch, let pruned):
      setState(.done(branch: branch, pruned: pruned), at: path)
    case .failed(let failure): setState(.failed(failure), at: path)
    }
  }

  /// 中断する。**実行中の 1 件は完走し、以降を撃たない**——途中で殺すと管理ディレクトリが半端に残り、
  /// 「消えかけの worktree」という新しい状態が生まれる。中断の価値はまだ撃っていない残りを止めること。
  ///
  /// 撃たれないと決まった待機はその場で `.skipped` へ落とす。中断は不可逆なので、
  /// 「まだ撃つものが残っている」と読める状態を残さない。
  func cancelRun() {
    guard phase == .deleting, var run else { return }
    runToken?.cancel()
    for index in run.states.indices where run.states[index] == .pending {
      run.states[index] = .skipped
    }
    self.run = run
  }

  /// 削除を畳んで選択画面へ戻す（失敗が 1 件も無かったときの終端）。
  func endRun() {
    run = nil
    runToken = nil
  }

  /// 失敗行だけの再実行の依頼を返す。**凍結した分類・凍結した依頼のまま**で、成功行は `.done` のまま
  /// 残る。中断の札も張り直す（中断後の再試行が即座に打ち切られない）。
  ///
  /// **失敗行はここでは待機へ戻さない**——実際に撃たれた行だけを `markRunning` が動かすので、
  /// 再試行の途中で中断しても、まだ撃っていない行は失敗のまま（理由と生ログごと）残る。
  ///
  /// ブランチ削除だけが落ちた行は worktree が既に消えているので、その事実を依頼へ書き戻す。
  func retryRequests() -> [CleanDeleteRequest] {
    guard phase == .failed, var run else { return [] }
    var out: [CleanDeleteRequest] = []
    for index in run.states.indices {
      guard case .failed(let failure) = run.states[index] else { continue }
      if failure.step == .branch { run.requests[index].worktreeAlreadyRemoved = true }
      out.append(run.requests[index])
    }
    guard !out.isEmpty else { return [] }
    self.run = run
    runToken = CleanRunToken()
    failureCursor = 0
    return out
  }

  var totalCount: Int { run?.requests.count ?? 0 }

  var doneCount: Int {
    run?.states.filter {
      if case .done = $0 { return true }
      return false
    }.count ?? 0
  }

  var failedCount: Int { failedIndices.count }

  /// 決着した件数（削除中の進捗ピルの分子）。**失敗も進んだうちに数える**——分母が総数なので、
  /// 成功だけを数えると ✓/✕ の付いた行数と食い違い、進捗が止まったように読める。
  var settledCount: Int { doneCount + failedCount }

  /// 可視域へ追従させる行 id。**画面ごとに追う対象が違う**ので、分岐は View でなくここが持つ
  /// （選択＝カーソル行 / 削除中＝実行中の行 / 一部失敗＝`⏎`・`o` の対象）。
  var scrollTargetID: String? {
    switch phase {
    case .selecting: return cursorRow?.id
    case .deleting:
      guard let run, let index = run.states.firstIndex(of: .running) else { return nil }
      return run.requests[index].path
    case .failed: return failureTargetPath
    }
  }

  /// 失敗行の index（`run.requests` を数えた並び順）。
  var failedIndices: [Int] {
    guard let run else { return [] }
    return run.states.indices.filter {
      if case .failed = run.states[$0] { return true }
      return false
    }
  }

  /// 一部失敗画面のカーソルが指す失敗行（ハイライトと `⏎` / `o` の対象）。
  var failureTargetPath: String? {
    let indices = failedIndices
    guard indices.indices.contains(failureCursor), let run else { return nil }
    return run.requests[indices[failureCursor]].path
  }

  /// `o タブで開く` で開ける失敗行。**ブランチ削除だけが落ちた行は worktree がもう無い**ので、
  /// 開く先が存在しない（案内も出さない）。
  var openableFailurePath: String? {
    guard let path = failureTargetPath, let run,
      let index = run.requests.firstIndex(where: { $0.path == path }),
      case .failed(let failure) = run.states[index], failure.step != .branch
    else { return nil }
    return path
  }

  // MARK: - 内部

  private func setChecked(_ isOn: Bool, at rowID: String) {
    if isOn {
      checked.insert(rowID)
    } else {
      checked.remove(rowID)
    }
  }

  /// index ではなくパスで書く。再試行では失敗行だけを撃ち直すので、実行器が数える index と
  /// `run.requests` の index は一致しない——**行 id（絶対パス）だけが両者をつなぐ唯一の鍵**。
  private func setState(_ state: CleanRunState, at path: String) {
    guard var run, let index = run.requests.firstIndex(where: { $0.path == path }) else { return }
    run.states[index] = state
    self.run = run
  }
}
