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
    /// ブランチ名指しの PR 取得（`--state all --head <branch>`）の着地。open / closed の両方の
    /// 事実がここから決まる——一覧の窓（直近 N 件）に頼ると、窓落ちした PR のぶんだけ
    /// 「merged チップが出ない」「レビュー中なのに安全確認を素通りする」が起きる。
    var branchPullRequests: [GitHubBranchPR] = []
    /// path → 分類レーンの実測。無い worktree は「判定できなかった」として扱う。
    var probes: [String: DispatchCleanProbe] = [:]
    var panes: [PaneOccupancy] = []
  }

  /// 各レーンから届いた事実を 1 worktree ぶんずつ突き合わせて行に落とす（レーンをまたぐ組み立ての SSOT）。
  static func rows(_ input: Input) -> [CleanRow] {
    let occupancy = occupancies(worktreePaths: input.worktrees.map(\.path), panes: input.panes)
    let branchByName = Dictionary(
      input.localBranches.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let prsByHead = branchPRLookup(input.branchPullRequests)
    return classify(
      input.worktrees.map { worktree in
        let probe = input.probes[worktree.path]
        let local = worktree.branch.flatMap { branchByName[$0] }
        let prs = worktree.branch.flatMap { prsByHead[$0] } ?? []
        return DispatchCleanFacts(
          path: worktree.path, branch: worktree.branch, head: worktree.head,
          isMain: worktree.isMain, isPrunable: worktree.isPrunable,
          lockReason: worktree.lockReason, upstream: local?.upstream, track: local?.track,
          closedPR: prs.first { $0.state != "OPEN" }.map {
            DispatchCleanPR(number: $0.number, isMerged: $0.state == "MERGED", base: $0.baseRefName)
          },
          openPR: prs.first { $0.state == "OPEN" }?.number,
          status: probe?.status, containment: probe?.containment,
          operation: probe?.operation ?? .unknown, occupancy: occupancy[worktree.path])
      })
  }

  /// PR 突き合わせの前処理（cross-repo 除外 → head ごとにまとめる）。`rows()` と
  /// `extraContainmentTargets` の両方が読む——**選択規約の分岐を作らない**ための SSOT。
  ///
  /// cross-repo の PR は他人の同名ブランチの事実として突き合わせの**前に**除外する
  /// （`--head` はブランチ名でしか絞れない）。この足切りは落とす方向にしか誤らない——外し損ねた
  /// 他人の PR で番号を騙るより、自分の PR を落として推定が 1 つ減る方を選ぶ（`isCrossRepository`
  /// が「他人の fork か」と一致しない形は `GitHubBranchPR` を見る）。gh の並びは作成日時の降順で、
  /// grouping は要素順を保つ——head ごとの先頭一致＝最新の PR を採る、という意味論がここで決まる。
  static func branchPRLookup(_ prs: [GitHubBranchPR]) -> [String: [GitHubBranchPR]] {
    Dictionary(grouping: prs.filter { !$0.isCrossRepository }, by: \.headRefName)
  }

  /// gh ヒント由来の追加比較先（path → `["origin/<base>"]`）。証明はローカルなので、
  /// `origin/<base>` がローカルに実在し（`remoteBranchNames`）、既定のローカル名と異なる場合だけ足す
  /// ——嘘・欠損の base は入口で落ち、残っても cherry の不成立で確認群のままに倒れる。
  /// PR の選択は `rows()` と同一規約（`branchPRLookup` → 最新の非 OPEN が MERGED のときだけ）。
  /// 対象は main worktree 以外・ブランチのある worktree（detached は PR の head になり得ない）。
  static func extraContainmentTargets(
    worktrees: [GitWorktree], branchPullRequests: [GitHubBranchPR],
    remoteBranchNames: Set<String>, defaultBranch: String
  ) -> [String: [String]] {
    let lookup = branchPRLookup(branchPullRequests)
    let defaultLocal = label(defaultBranch)
    var out: [String: [String]] = [:]
    for worktree in worktrees where !worktree.isMain {
      guard let branch = worktree.branch,
        let pr = lookup[branch]?.first(where: { $0.state != "OPEN" }), pr.state == "MERGED",
        pr.baseRefName != defaultLocal, remoteBranchNames.contains("origin/\(pr.baseRefName)")
      else { continue }
      out[worktree.path] = ["origin/\(pr.baseRefName)"]
    }
    return out
  }

  /// 群順（safe → caution → inUse）に並べた行を返す。群内は入力順。
  static func classify(_ facts: [DispatchCleanFacts]) -> [CleanRow] {
    let rows = facts.map { row($0) }
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

  /// コミットが世界に残ることの証明が立っているか（到達性または比較先への patch 等価）。
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

  /// 行の語彙 4 本（3 軸＋判定不能）。`cluster` へまとめて渡すための束。
  private struct AxisSet {
    let a: [CleanChip]
    let b: [CleanChip]
    let c: [CleanChip]
    let unverified: [CleanChip]
    var vocabulary: [CleanChip] { a + b + c + unverified }
  }

  private static func row(_ f: DispatchCleanFacts) -> CleanRow {
    let group = group(f)
    let axes = AxisSet(
      a: axisA(f, group), b: group == .inUse ? [] : axisB(f), c: axisC(f),
      unverified: unverified(f, group))
    let vocabulary = axes.vocabulary
    let lossNotes = vocabulary.filter(\.isLoss)
    let cluster = self.cluster(f, group, axes)
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
    _ f: DispatchCleanFacts, _ group: CleanGroup, _ axes: AxisSet
  ) -> (chips: [CleanChip], overflow: [CleanChip]) {
    // merged PR チップが立つ行では `.mergedInto` はピル枠を争わずサブライン（overflow）へ降りる
    // ——「PR #N merged → base」と同じ「merged」を 2 枚並べない。空いた枠は次の事実（[gone] 等）
    // が rest から埋める。
    //
    // **降ろすのは重複する `.mergedInto` だけ。** `.savedOnRemote` は「到達性は立つがマージとまでは
    // 主張しない」という別の（かつローカルに証明された）主張なので PR チップと重複せず、しかも
    // overflow は `canExpandSubline` が確認群限定なので safe 行では描かれない——降ろせば消える。
    // 降ろすと safe 行に残る安全根拠が gh 由来の主張だけになり、「証明はローカルに閉じる」と逆を向く。
    let hasMergedPR = axes.b.contains {
      if case .mergedPR = $0 { return true }
      return false
    }
    let demoted =
      hasMergedPR
      ? axes.b.filter {
        if case .mergedInto = $0 { return true }
        return false
      } : []
    let candidates = [axes.a, axes.b.filter { !demoted.contains($0) }, axes.c, axes.unverified]
      .map { $0.filter(\.isPill) }
    let heads = candidates.compactMap(\.first)
    let rest = candidates.flatMap { $0.dropFirst() }
    var pills = heads
    if pills.count > 2 {
      pills = Array(
        (pills.filter { $0.tone == .loss } + pills.filter { $0.tone != .loss }).prefix(2))
    } else if pills.count < 2 {
      pills += rest.prefix(2 - pills.count)
    }
    var plains = axes.a.filter { !$0.isPill } + axes.c.filter { !$0.isPill }
    if group == .safe, f.branch != nil, !f.isPrunable { plains.append(.branchAlsoDeleted) }
    return (pills + plains, (heads + rest + demoted).filter { !pills.contains($0) })
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
  /// 到達可能か、比較先に patch 等価で在り、失うものが無い。判定ができなかった行
  /// （`nil`）では言い切れないので、従来どおり損失として名乗る。
  ///
  /// 取り込みの語は証明の種類で出し分ける: `.patchEquivalent` と tip を含む比較先のある
  /// `.reachable` は「merged → \<実マージ先\>」が真の主張なので名乗る。`.reachable(mergedInto: nil)`
  /// は単に完全 push 済みで未マージでも立つため「merged」を名乗らせず、到達性だけを主張する
  /// `.savedOnRemote` を出す（語が主張として偽になるなら、色を弱めるのではなく言わない）。
  private static func axisB(_ f: DispatchCleanFacts) -> [CleanChip] {
    guard f.branch != nil else { return [] }
    let contained = isContained(f.containment)
    // `remote に同期済み` が立つ条件。`remote に保存済み` の抑制条件と同一なので 1 箇所で持つ
    // （2 つのコピーに割ると、片方だけ動いたとき「両方出る／両方出ない」に静かに壊れる）。
    let isRemoteSynced = f.upstream != nil && f.track == nil
    var out: [CleanChip] = []
    if case .unmerged(let count) = f.containment { out.append(.ownCommits(count)) }
    if let number = f.openPR { out.append(.openPR(number)) }
    if f.upstream == nil, !contained { out.append(.unpushed) }
    if let ahead = ahead(f.track), ahead > 0, !contained { out.append(.remoteAhead(ahead)) }
    if let pr = f.closedPR, pr.isMerged { out.append(.mergedPR(pr.number, base: pr.base)) }
    switch f.containment {
    case .patchEquivalent(let target), .reachable(mergedInto: .some(let target)):
      out.append(.mergedInto(label(target)))
    case .reachable(mergedInto: nil):
      // 「remote に同期済み」が立つ行では「remote に保存済み」を名乗らない——同期済みが保存済みを
      // 含意し、強い方の主張が同じ事実を含んで立っている（隠される情報は無い）。
      if !isRemoteSynced { out.append(.savedOnRemote) }
    case .unmerged, nil:
      break
    }
    if isRemoteSynced { out.append(.remoteSynced) }
    if f.isGone { out.append(.gone) }
    return out
  }

  /// 安全確認に使う事実を確かめられなかったことの可視化（確認群限定。inUse は probe 自体を省く行で、
  /// safe は全確認済みの含意）。分類は変えない——判定不能を安全と読まない契約は分類側が持つ。
  private static func unverified(_ f: DispatchCleanFacts, _ group: CleanGroup) -> [CleanChip] {
    guard group == .caution else { return [] }
    // prunable は作業ツリー側（status・停止中の操作）を意図的に問わない（失うものが無く、
    // 確認の対象ですらない）。取り込み判定は detached も oid で問うので branch の有無を問わない。
    let status = !f.isPrunable && f.status == nil
    let operation = !f.isPrunable && f.operation == .unknown
    let containment = f.containment == nil
    guard status || operation || containment else { return [] }
    return [.unverified]
  }

  /// remote 追跡名からローカル名を取る（先頭の `origin/` を落とす。verdict は渡された名前そのままを
  /// 運ぶ）。**表示にも既定名の突き合わせにも使う**——gh の `baseRefName` は常に prefix 無しなので、
  /// 比較先候補が既定と同じかを見るときも同じ正規化を通す。
  private static func label(_ target: String) -> String {
    let prefix = "origin/"
    guard target.hasPrefix(prefix) else { return target }
    return String(target.dropFirst(prefix.count))
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
