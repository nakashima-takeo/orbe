import Foundation

/// worktree を「安全に消せる／理由を確認してから／消せない」の 3 群へ振り分ける純粋関数。
///
/// **「要らないの推定」と「消して安全か」は別のレイヤ**として別々に評価する。推定はどれか 1 つ立てば
/// 足り、安全確認は 1 つでも落ちれば safe に入らない——初期チェックに入る行は必ず全確認を通っている。
enum DispatchWorktreeClassifier {

  /// 分類の入力（各レーンが別々に着地するので、揃った順に埋めて渡す。`DispatchSectionBuilder.Input`
  /// と同じ流儀）。
  struct Input {
    var worktrees: [GitWorktree] = []
    var localBranches: [GitBranch] = []
    var closedPullRequests: [GitHubClosedPR] = []
    var openPullRequests: [GitHubPullRequest] = []
    /// path → 分類レーンの実測。無い worktree は「判定できなかった」として扱う。
    var probes: [String: DispatchCleanProbe] = [:]
    var panes: [PaneOccupancy] = []
    /// 行に出す既定ブランチ名。**表示専用**——取り込み判定の比較対象（`origin/main` のような remote
    /// 追跡 ref）は分類レーンが持っており、ここへは同じ値をそのまま流さない。
    var defaultBranchLabel = "main"
  }

  /// 各レーンから届いた事実を 1 worktree ぶんずつ突き合わせて行に落とす（レーンをまたぐ組み立ての SSOT）。
  static func rows(_ input: Input) -> [CleanRow] {
    let occupancy = occupancies(worktreePaths: input.worktrees.map(\.path), panes: input.panes)
    let branchByName = Dictionary(
      input.localBranches.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let closedByHead = Dictionary(
      input.closedPullRequests.map { ($0.headRefName, $0) }, uniquingKeysWith: { first, _ in first }
    )
    let openByHead = Dictionary(
      input.openPullRequests.map { ($0.headRefName, $0) }, uniquingKeysWith: { first, _ in first })
    return classify(
      input.worktrees.map { worktree in
        let probe = input.probes[worktree.path]
        let local = worktree.branch.flatMap { branchByName[$0] }
        let closed = worktree.branch.flatMap { closedByHead[$0] }
        return DispatchCleanFacts(
          path: worktree.path, branch: worktree.branch, head: worktree.head,
          isMain: worktree.isMain, isPrunable: worktree.isPrunable,
          lockReason: worktree.lockReason, upstream: local?.upstream, track: local?.track,
          closedPR: closed.map {
            DispatchCleanPR(number: $0.number, isMerged: $0.state == "MERGED", base: $0.baseRefName)
          },
          openPR: worktree.branch.flatMap { openByHead[$0]?.number },
          status: probe?.status, containment: probe?.containment,
          operation: probe?.operation ?? .unknown, occupancy: occupancy[worktree.path])
      }, defaultBranchLabel: input.defaultBranchLabel)
  }

  /// 群順（safe → caution → inUse）に並べた行を返す。群内は入力順。
  static func classify(_ facts: [DispatchCleanFacts], defaultBranchLabel: String = "main")
    -> [CleanRow]
  {
    let rows = facts.map { row($0, defaultBranchLabel: defaultBranchLabel) }
    return [CleanGroup.safe, .caution, .inUse].flatMap { group in
      rows.filter { $0.group == group }
    }
  }

  /// safe 群の件数（list モードの `候補 N 件` バッジの元。リテラルを持たない）。
  static func candidateCount(_ rows: [CleanRow]) -> Int {
    rows.filter { $0.group == .safe }.count
  }

  // MARK: - 2 レイヤ

  /// 削除候補としての推定。どれか 1 つでも立てば「推定あり」。
  private static func hasHint(_ f: DispatchCleanFacts) -> Bool {
    f.isGone || f.closedPR?.isMerged == true || f.isPrunable
  }

  /// 消えて困るものが無いことの直接確認。**すべて**通ってはじめて safe。
  /// 実体が無い（prunable）ときは「ディスク上に失うものが無い」ので、作業ツリー側の 2 項目
  /// （status と停止中の操作）は自動的に満たす。
  ///
  /// **open PR のある行は safe に入れない。** 安全群はブランチ削除が無条件になる群だが、
  /// レビュー中のブランチの既定は「残す」——初期チェック済みで並べると、確認の機会が無いまま
  /// レビュー中のブランチが消える。ここを開けておくと「安全の根拠を隠したまま黄の警告だけを出す
  /// 安全行」も作れてしまう（安全群に loss の語が 1 つも立たないことが、この 1 行で決まる）。
  private static func passesSafety(_ f: DispatchCleanFacts) -> Bool {
    guard !f.isMain, f.occupancy == nil, f.lockReason == nil, f.openPR == nil else { return false }
    guard f.isPrunable || f.status?.isClean == true else { return false }
    // **status が clean でも rebase 途中の worktree は safe に入れない。** コンフリクトの無い停止点では
    // status が空になりうるので、status だけを見ていると初期チェック済みのまま消える。
    guard f.isPrunable || f.operation == .none else { return false }
    return isContained(f.containment)
  }

  /// コミットが世界に残ることの証明が立っているか（到達性または既定ブランチへの patch 等価）。
  /// nil（判定できなかった）と `.unmerged` はどちらも false——分からないものを安全と読まない。
  private static func isContained(_ containment: GitBranchContainment?) -> Bool {
    switch containment {
    case .reachable, .patchEquivalent: return true
    case .unmerged, nil: return false
    }
  }

  private static func group(_ f: DispatchCleanFacts) -> CleanGroup {
    if f.isMain || f.occupancy != nil { return .inUse }
    return hasHint(f) && passesSafety(f) ? .safe : .caution
  }

  // MARK: - 行の組み立て

  private static func row(_ f: DispatchCleanFacts, defaultBranchLabel: String) -> CleanRow {
    let group = group(f)
    let axisA = self.axisA(f, group)
    let axisB = group == .inUse ? [] : self.axisB(f, defaultBranchLabel: defaultBranchLabel)
    let axisC = self.axisC(f)
    let vocabulary = axisA + axisB + axisC
    let lossNotes = vocabulary.filter(\.isLoss)
    let cluster = self.cluster(f, group, axisA: axisA, axisB: axisB, axisC: axisC)
    return CleanRow(
      id: f.path, name: (f.path as NSString).lastPathComponent,
      meta: f.branch ?? abbreviate(f.path), branch: f.branch, head: f.head, group: group,
      vocabulary: vocabulary, chips: cluster.chips, lossNotes: lossNotes,
      overflowNotes: cluster.overflow.filter { !lossNotes.contains($0) },
      deletesBranchImplicitly: group == .safe && !f.isPrunable && f.branch != nil)
  }

  /// 右クラスタと、そこへ載らなかったピル候補。
  ///
  /// **上限の 2 枚はまず各軸の 1 枚目に配る**（軸をまたぐ事実を片方に潰させない）。3 軸が競合したら
  /// loss を優先して 2 枚へ切り詰め、**逆に黙っている軸があって枠が余ったら、残りの語で埋める**——
  /// 「最大 2 枚」は「軸ごとに 1 枚まで」ではないので、軸A が何も名乗らない行では軸B が 2 枚出る。
  /// 枠を空けたまま候補を捨てると、安全行が安全の根拠を 1 つしか出さないまま黙る。
  ///
  /// **切り詰めた候補は捨てずに返す**——受け皿を損失の内訳と兼ねると、`locked` のように損失では
  /// ない語がどこにも出なくなる。素文字（軸C の使用状況・safe 行の注記）は上限の外なのでピルの後に
  /// そのまま続く。
  private static func cluster(
    _ f: DispatchCleanFacts, _ group: CleanGroup, axisA: [CleanChip], axisB: [CleanChip],
    axisC: [CleanChip]
  ) -> (chips: [CleanChip], overflow: [CleanChip]) {
    let axes = [axisA, axisB, axisC].map { $0.filter(\.isPill) }
    let heads = axes.compactMap(\.first)
    let rest = axes.flatMap { $0.dropFirst() }
    var pills = heads
    if pills.count > 2 {
      pills = Array(
        (pills.filter { $0.tone == .loss } + pills.filter { $0.tone != .loss }).prefix(2))
    } else if pills.count < 2 {
      pills += rest.prefix(2 - pills.count)
    }
    var plains = axisA.filter { !$0.isPill } + axisC.filter { !$0.isPill }
    if group == .safe, f.branch != nil, !f.isPrunable { plains.append(.branchAlsoDeleted) }
    return (pills + plains, (heads + rest).filter { !pills.contains($0) })
  }

  /// 軸A（消すと何を失うか）。優先順位は `進行中 > 未コミット > untracked > prunable`。
  /// **失うものが無い行は何も名乗らない**——安全群の見出しと行内の `ブランチも削除` が
  /// 既に同じことを言っており、群の中では冗長になる。
  private static func axisA(_ f: DispatchCleanFacts, _ group: CleanGroup) -> [CleanChip] {
    guard group != .inUse else { return [] }
    var out: [CleanChip] = []
    if !f.isPrunable, case .inProgress(let operation) = f.operation {
      out.append(.inProgress(operation))
    }
    if !f.isPrunable, let status = f.status {
      if status.modified > 0 { out.append(.uncommitted(status.modified)) }
      if status.untracked > 0 { out.append(.untracked(status.untracked)) }
    }
    if f.isPrunable { out.append(.prunable) }
    return out
  }

  /// 軸B（消すと世界に残るか）。優先順位は**損失を隠さない順**。
  /// detached（`branch == nil`）は行き先そのものが無いので何も名乗らない。
  ///
  /// `未 push · ローカルのみ` と `remote +N` は**「そのコミットがどこにも残らない」という主張**なので、
  /// コミットが世界に残ると確認済み（`isContained`）の行では言わない——remote-tracking ref から
  /// 到達可能か、既定ブランチに patch 等価で在り、失うものが無い。判定ができなかった行
  /// （`nil`）では言い切れないので、従来どおり損失として名乗る。
  ///
  /// 取り込みの語は証明の種類で出し分ける: `.patchEquivalent` と `.reachable(mergedIntoDefault: true)`
  /// は「merged → \<default\>」が真の主張なので名乗る。`.reachable(mergedIntoDefault: false)` は
  /// 単に完全 push 済みで未マージでも立つため「merged」を名乗らせず、到達性だけを主張する
  /// `.savedOnRemote` を出す（語が主張として偽になるなら、色を弱めるのではなく言わない）。
  private static func axisB(_ f: DispatchCleanFacts, defaultBranchLabel: String) -> [CleanChip] {
    guard f.branch != nil else { return [] }
    let contained = isContained(f.containment)
    var out: [CleanChip] = []
    if case .unmerged(let count) = f.containment { out.append(.ownCommits(count)) }
    if let number = f.openPR { out.append(.openPR(number)) }
    if f.upstream == nil, !contained { out.append(.unpushed) }
    if let ahead = ahead(f.track), ahead > 0, !contained { out.append(.remoteAhead(ahead)) }
    if let pr = f.closedPR, pr.isMerged { out.append(.mergedPR(pr.number, base: pr.base)) }
    switch f.containment {
    case .patchEquivalent, .reachable(mergedIntoDefault: true):
      out.append(.mergedIntoDefault(defaultBranchLabel))
    case .reachable(mergedIntoDefault: false):
      out.append(.savedOnRemote)
    case .unmerged, nil:
      break
    }
    if f.upstream != nil, f.track == nil { out.append(.remoteSynced) }
    if f.isGone { out.append(.gone) }
    return out
  }

  /// 軸C（使用状況）。`locked` を除いて素文字で、群の移動そのものが「使用中」を表す。
  private static func axisC(_ f: DispatchCleanFacts) -> [CleanChip] {
    var out: [CleanChip] = []
    if f.lockReason != nil { out.append(.locked) }
    // main worktree は常に削除不可という 1 つの事実で言い切る（ペインの有無を重ねて言わない）。
    if f.isMain { return out + [.mainWorktree] }
    guard let occupancy = f.occupancy else { return out }
    switch occupancy.agentState {
    case "working": out.append(.agentWorking)
    case "waiting": out.append(.agentWaiting)
    default: out.append(.paneOpen)
    }
    return out
  }

  /// `%(upstream:track)` の `[ahead N]`（`[ahead 1, behind 2]` も拾う）。
  private static func ahead(_ track: String?) -> Int? {
    guard let track, let range = track.range(of: "ahead ") else { return nil }
    return Int(track[range.upperBound...].prefix { $0.isNumber })
  }

  private static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  // MARK: - ペイン占有の帰属

  /// ペイン群を worktree のパスへ帰属させる。
  ///
  /// - 両辺を `standardizingPath` → `resolvingSymlinksInPath` で正規化する（macOS では `/tmp` `/var` が
  ///   symlink で、OSC 7 の pwd と `git worktree list` のパスが素では一致しない）。
  /// - 子ディレクトリにいるペインも占有とみなす。判定は**パス構成要素単位**の前置一致で、
  ///   文字列 prefix ではない（`/a/foo` が `/a/foobar` に誤ヒットする）。
  /// - worktree が入れ子になっている構成があるので**最も長く一致した worktree に帰属**させる
  ///   （1 つのペインを親と子の両方の占有にしない）。
  /// - 同じ worktree に複数のペインが居たら `AgentRollup.priorityOrder` で状態を 1 つに畳む。
  static func occupancies(worktreePaths: [String], panes: [PaneOccupancy])
    -> [String: PaneOccupancy]
  {
    let normalized = worktreePaths.map { ($0, components($0)) }
    var out: [String: PaneOccupancy] = [:]
    for pane in panes {
      let paneComponents = components(pane.cwd)
      let owner =
        normalized
        .filter { isPrefix($0.1, of: paneComponents) }
        .max { $0.1.count < $1.1.count }
      guard let owner else { continue }
      out[owner.0] = merge(out[owner.0], pane)
    }
    return out
  }

  /// 同じ worktree を占めるペインの状態を 1 つに畳む（waiting > working > done > その他）。
  private static func merge(_ current: PaneOccupancy?, _ next: PaneOccupancy) -> PaneOccupancy {
    guard let current else { return next }
    return priority(next.agentState) < priority(current.agentState) ? next : current
  }

  private static func priority(_ state: String?) -> Int {
    guard let state, let index = AgentRollup.priorityOrder.firstIndex(of: state) else {
      return AgentRollup.priorityOrder.count
    }
    return index
  }

  private static func components(_ path: String) -> [String] {
    ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
      .split(separator: "/").map(String.init)
  }

  private static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
    prefix.count <= path.count && Array(path.prefix(prefix.count)) == prefix
  }
}
