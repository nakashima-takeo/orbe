import Foundation

/// clean 画面の 3 群。inUse=物理的に消せない / safe=推定が立ち安全確認を全部通った / caution=残り全部。
enum CleanGroup: Equatable {
  case safe, caution, inUse
}

/// clean 行末のチップ。**文言は View が言語別に引き**、ここは意味と数値だけを持つ
/// （`DispatchInfoKind` / `DispatchWorktreeKind` と同じ流儀）。
enum CleanChip: Equatable, Identifiable {
  /// PR が MERGED（緑）。
  case mergedPR(Int)
  /// upstream が消えている（灰・git の生の語なので L10n しない）。
  case gone
  /// ディスク上に実体が無い（灰）。
  case prunable
  /// 未コミット変更あり（琥珀）。
  case dirty
  /// 未マージのまま閉じた PR ＋独自コミット k 件（琥珀）。
  case unmergedClosed(Int)
  /// 独自コミット k 件（琥珀）。
  case ownCommits(Int)
  /// worktree が locked（琥珀）。
  case locked
  /// `clean · +0`（地なし・緑の注記）。
  case cleanNote
  /// main worktree（地なし・muted）。
  case mainWorktree
  /// ペインが開いている（地なし・muted）。agent 作業中なら working グリフを前置する。
  case paneOpen(working: Bool)

  var id: String {
    switch self {
    case .mergedPR(let n): return "merged:\(n)"
    case .gone: return "gone"
    case .prunable: return "prunable"
    case .dirty: return "dirty"
    case .unmergedClosed(let k): return "unmergedClosed:\(k)"
    case .ownCommits(let k): return "ownCommits:\(k)"
    case .locked: return "locked"
    case .cleanNote: return "cleanNote"
    case .mainWorktree: return "mainWorktree"
    case .paneOpen(let working): return "paneOpen:\(working)"
    }
  }
}

/// clean 画面の 1 行（分類の出力。画面に入った瞬間に凍結されるスナップショットの要素）。
struct CleanRow: Identifiable, Equatable {
  /// worktree の絶対パス（一意）。
  let id: String
  /// パスの末尾要素。
  let name: String
  /// `<~省略パス> · <branch>`。
  let meta: String
  let branch: String?
  /// 分類した時点の HEAD の oid。ブランチ削除を「この先端のときだけ」に絞るために運ぶ
  /// （凍結した判定のままコミットを消さない）。
  let head: String
  let group: CleanGroup
  /// 行末チップ列（群ごとの語彙）。
  let chips: [CleanChip]
}

/// ペインが開いているディレクトリのスナップショット（`SessionStore` を Dispatch から見せないための値型）。
struct PaneOccupancy: Equatable {
  /// ペインの実効 cwd。
  let cwd: String
  /// agent の状態（`working` / `waiting` / `done` / `idle`）。素のシェルなら nil。
  let agentState: String?
}

/// 紐づく closed PR（掃除の推定と caution の理由に使う）。
struct DispatchCleanPR: Equatable {
  let number: Int
  let isMerged: Bool
}

/// 分類の入力 1 件。git / gh / ペイン走査から採った素の事実だけを持ち、subprocess には依存しない。
struct DispatchCleanFacts: Equatable {
  let path: String
  let branch: String?
  /// HEAD の oid（ブランチ削除の compare-and-delete に運ぶ）。
  let head: String
  let isMain: Bool
  /// ディスク上の実体が失われている。
  let isPrunable: Bool
  /// locked の理由（locked でなければ nil）。
  let lockReason: String?
  /// upstream が `[gone]`。
  let isGone: Bool
  /// ブランチに紐づく closed PR。
  let closedPR: DispatchCleanPR?
  /// 作業ツリーに未コミット変更がある。
  let isDirty: Bool
  /// 既定ブランチに取り込まれていない独自コミット数。0 で取り込み済み、nil で判定できなかった。
  let unmergedCommits: Int?
  /// このパスを開いているペイン（複数あれば状態を 1 つに畳んだもの）。
  let occupancy: PaneOccupancy?

  /// 既定値は**すべて安全側**に置く。とりわけ `unmergedCommits` は「判定できなかった」を意味する nil で、
  /// 省略しただけの事実が「取り込み済み＝消してよい」と名乗ることはない（既定値を第 2 の判断点にしない）。
  init(
    path: String, branch: String? = nil, head: String = "", isMain: Bool = false,
    isPrunable: Bool = false, lockReason: String? = nil, isGone: Bool = false,
    closedPR: DispatchCleanPR? = nil, isDirty: Bool = false, unmergedCommits: Int? = nil,
    occupancy: PaneOccupancy? = nil
  ) {
    self.path = path
    self.branch = branch
    self.head = head
    self.isMain = isMain
    self.isPrunable = isPrunable
    self.lockReason = lockReason
    self.isGone = isGone
    self.closedPR = closedPR
    self.isDirty = isDirty
    self.unmergedCommits = unmergedCommits
    self.occupancy = occupancy
  }
}

/// 分類レーンが 1 worktree について実測した事実。
struct DispatchCleanProbe: Equatable {
  var isDirty = false
  /// 取り込み済みなら 0、未取り込みなら独自コミット件数、判定できなければ nil。
  var unmergedCommits: Int?
}

/// worktree を「安全に消せる／理由を確認してから／消せない」の 3 群へ振り分ける純粋関数。
///
/// **「要らないの推定」と「消して安全か」は別のレイヤ**として別々に評価する。推定はどれか 1 つ立てば
/// 足り、安全確認は 1 つでも落ちれば safe に入らない——初期チェックに入る行は必ず全確認を通っている。
enum DispatchWorktreeClassifier {

  /// 各レーンから届いた事実を 1 worktree ぶんずつ突き合わせて行に落とす（レーンをまたぐ組み立ての SSOT）。
  /// 実測が無い worktree（inUse と判ってプローブを省いた行）は「判定できなかった」として扱う。
  static func rows(
    worktrees: [GitWorktree], localBranches: [GitBranch],
    closedPullRequests: [GitHubClosedPR], probes: [String: DispatchCleanProbe],
    panes: [PaneOccupancy]
  ) -> [CleanRow] {
    let occupancy = occupancies(worktreePaths: worktrees.map(\.path), panes: panes)
    let trackByBranch = Dictionary(
      localBranches.map { ($0.name, $0.track) }, uniquingKeysWith: { first, _ in first })
    let prByHead = Dictionary(
      closedPullRequests.map { ($0.headRefName, $0) }, uniquingKeysWith: { first, _ in first })
    return classify(
      worktrees.map { worktree in
        let probe = probes[worktree.path]
        let pr = worktree.branch.flatMap { prByHead[$0] }
        return DispatchCleanFacts(
          path: worktree.path, branch: worktree.branch, head: worktree.head,
          isMain: worktree.isMain,
          isPrunable: worktree.isPrunable, lockReason: worktree.lockReason,
          isGone: worktree.branch.flatMap { trackByBranch[$0] ?? nil } == "[gone]",
          closedPR: pr.map { DispatchCleanPR(number: $0.number, isMerged: $0.state == "MERGED") },
          isDirty: probe?.isDirty ?? false, unmergedCommits: probe?.unmergedCommits,
          occupancy: occupancy[worktree.path])
      })
  }

  /// 群順（safe → caution → inUse）に並べた行を返す。群内は入力順。
  static func classify(_ facts: [DispatchCleanFacts]) -> [CleanRow] {
    let rows = facts.map(row)
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
  /// 実体が無い（prunable）ときは「ディスク上に失うものが無い」ので dirty の項目は自動的に満たす。
  private static func passesSafety(_ f: DispatchCleanFacts) -> Bool {
    guard !f.isMain, f.occupancy == nil, f.lockReason == nil else { return false }
    guard f.isPrunable || !f.isDirty else { return false }
    return f.unmergedCommits == 0
  }

  private static func group(_ f: DispatchCleanFacts) -> CleanGroup {
    if f.isMain || f.occupancy != nil { return .inUse }
    return hasHint(f) && passesSafety(f) ? .safe : .caution
  }

  // MARK: - 行の組み立て

  private static func row(_ f: DispatchCleanFacts) -> CleanRow {
    let group = group(f)
    var meta = abbreviate(f.path)
    if let branch = f.branch { meta += " · \(branch)" }
    return CleanRow(
      id: f.path, name: (f.path as NSString).lastPathComponent, meta: meta, branch: f.branch,
      head: f.head, group: group, chips: chips(f, group))
  }

  /// 行末チップをデータから導く（リテラルの並びを持たない）。
  /// inUse は「なぜ消せないか」だけ、それ以外は推定チップ→落ちた安全確認の理由→注記の順。
  private static func chips(_ f: DispatchCleanFacts, _ group: CleanGroup) -> [CleanChip] {
    if group == .inUse {
      if f.isMain { return [.mainWorktree] }
      return [.paneOpen(working: f.occupancy?.agentState == "working")]
    }
    var out: [CleanChip] = []
    if let pr = f.closedPR, pr.isMerged { out.append(.mergedPR(pr.number)) }
    if f.isGone { out.append(.gone) }
    if f.isPrunable { out.append(.prunable) }
    if !f.isPrunable, f.isDirty { out.append(.dirty) }
    if let unmerged = f.unmergedCommits, unmerged > 0 {
      out.append(
        f.closedPR?.isMerged == false ? .unmergedClosed(unmerged) : .ownCommits(unmerged))
    }
    if f.lockReason != nil { out.append(.locked) }
    // `clean · +0` は実体のあるディレクトリで status と取り込み済み判定の両方が通った safe 行だけ。
    // prunable 行は「clean」を名乗る作業ツリーが無いので出さない。
    if group == .safe, !f.isPrunable { out.append(.cleanNote) }
    return out
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
