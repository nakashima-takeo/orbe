import Foundation

// clean 画面の状態語彙（3 軸）と、分類の入出力の値型。**行の状態は独立した 3 軸の直積**で、
// 単一の列挙では網羅できない——という確定版の中核主張をコードの形で保つため、軸の語彙・トーン・
// 群を 1 箇所に置き、分類器（`DispatchWorktreeClassifier`）と View が同じ定義を読む。

/// clean 画面の 3 群。inUse=物理的に消せない / safe=推定が立ち安全確認を全部通った / caution=残り全部。
enum CleanGroup: Equatable {
  case safe, caution, inUse
}

/// 行の語彙のトーン。**色そのものではなく「何を意味するか」**で持ち、色は View が 1 段の写像で付ける。
/// 語彙が増えても色の付け方が分岐しないための 1 段で、`loss`=失うものがある / `safe`=損失ゼロの根拠 /
/// `neutral`=中立な事実 / `danger`=失敗 / `status`=agent 稼働。
enum CleanTone: Equatable {
  case loss, safe, neutral, danger, status
}

/// clean 行の右クラスタの 1 要素。行の状態は**独立した 3 軸の直積**で、単一の列挙では網羅できない——
/// 軸A=worktree の中身（消すと何を失うか）／軸B=ブランチの行き先（消すと世界に残るか）／
/// 軸C=使用状況（ピルでなく群移動。`locked` だけ例外的にピル）。
/// **文言は View が言語別に引き**、ここは意味と数値だけを持つ。
enum CleanChip: Equatable, Identifiable {
  // MARK: 軸A — worktree の中身
  /// 何も失わない（実体があり status も取り込み判定も通った safe 行だけ）。
  case cleanNote
  /// tracked の未コミット変更（staged 含む）。
  case uncommitted(Int)
  case untracked(Int)
  /// 停止している git 操作（`rebase` / `merge` / `cherry-pick` / `bisect`）。
  case inProgress(GitWorktreeOperation)
  /// ディスク上に実体が無い。
  case prunable

  // MARK: 軸B — ブランチの行き先
  case mergedPR(Int)
  /// 既定ブランチへ取り込み済み（引数は既定ブランチ名）。
  case mergedIntoDefault(String)
  case remoteSynced
  /// upstream より k コミット先行している。
  case remoteAhead(Int)
  case unpushed
  case openPR(Int)
  /// upstream が消えている。
  case gone
  /// 既定ブランチに取り込まれていない独自コミット k 件。
  case ownCommits(Int)

  // MARK: 軸C — 使用状況
  case agentWorking
  case agentWaiting
  case paneOpen
  case locked
  case mainWorktree

  // MARK: 行内注記
  /// safe 行の `merged ブランチも削除`（チェックすればブランチごと消えることの明示）。
  case branchAlsoDeleted

  var id: String {
    switch self {
    case .cleanNote: return "cleanNote"
    case .uncommitted(let n): return "uncommitted:\(n)"
    case .untracked(let n): return "untracked:\(n)"
    case .inProgress(let op): return "inProgress:\(op.name)"
    case .prunable: return "prunable"
    case .mergedPR(let n): return "mergedPR:\(n)"
    case .mergedIntoDefault(let branch): return "mergedIntoDefault:\(branch)"
    case .remoteSynced: return "remoteSynced"
    case .remoteAhead(let n): return "remoteAhead:\(n)"
    case .unpushed: return "unpushed"
    case .openPR(let n): return "openPR:\(n)"
    case .gone: return "gone"
    case .ownCommits(let n): return "ownCommits:\(n)"
    case .agentWorking: return "agentWorking"
    case .agentWaiting: return "agentWaiting"
    case .paneOpen: return "paneOpen"
    case .locked: return "locked"
    case .mainWorktree: return "mainWorktree"
    case .branchAlsoDeleted: return "branchAlsoDeleted"
    }
  }

  var tone: CleanTone {
    switch self {
    case .cleanNote, .mergedPR, .mergedIntoDefault: return .safe
    case .uncommitted, .untracked, .inProgress, .remoteAhead, .unpushed, .openPR, .ownCommits,
      .locked, .agentWaiting:
      return .loss
    case .prunable, .remoteSynced, .gone, .paneOpen, .mainWorktree, .branchAlsoDeleted:
      return .neutral
    case .agentWorking: return .status
    }
  }

  /// 塗りのあるピルか（false は塗らない素文字）。軸C は `locked` を除いて素文字で、
  /// 使用状況は「ピルを増やす」のではなく群の移動そのものが表す。
  var isPill: Bool {
    switch self {
    case .cleanNote, .agentWorking, .agentWaiting, .paneOpen, .mainWorktree, .branchAlsoDeleted:
      return false
    default:
      return true
    }
  }
}

/// clean 画面の 1 行（分類の出力。画面に入った瞬間に凍結されるスナップショットの要素）。
struct CleanRow: Identifiable, Equatable {
  /// worktree の絶対パス（一意）。
  let id: String
  /// パスの末尾要素。
  let name: String
  /// meta 列。**ブランチ名だけ**（パスは list モードが見せる）。detached はパスへ落とす。
  let meta: String
  let branch: String?
  /// 分類した時点の HEAD の oid。ブランチ削除を「この先端のときだけ」に絞るために運ぶ
  /// （凍結した判定のままコミットを消さない）。
  let head: String
  let group: CleanGroup
  /// 右クラスタ（ピルは軸A + 軸B の最大 2 枚、その後に素文字と注記）。
  let chips: [CleanChip]
  /// 展開サブラインへ書く損失の内訳（loss トーンの語彙すべて。ピルへ出たものも含む）。
  let lossNotes: [CleanChip]
  /// チェックするとブランチも一緒に消える行（safe 群のうち、実体があってブランチを持つ行）。
  let deletesBranchImplicitly: Bool
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
  /// upstream の短縮名（`origin/x`）。無ければ未 push。
  let upstream: String?
  /// `%(upstream:track)`（`[gone]` / `[ahead 1]` 等）。空なら nil。
  let track: String?
  /// ブランチに紐づく closed PR。
  let closedPR: DispatchCleanPR?
  /// ブランチに紐づく open PR の番号。
  let openPR: Int?
  /// `status --porcelain` の件数。nil で判定できなかった。
  let status: GitWorktreeStatusCounts?
  /// 既定ブランチに取り込まれていない独自コミット数。0 で取り込み済み、nil で判定できなかった。
  let unmergedCommits: Int?
  /// 停止している git 操作。
  let operation: GitWorktreeOperationState
  /// このパスを開いているペイン（複数あれば状態を 1 つに畳んだもの）。
  let occupancy: PaneOccupancy?

  /// 既定値は**すべて安全側**に置く。とりわけ `unmergedCommits`（nil）と `operation`（`.unknown`）は
  /// 「判定できなかった」を意味し、省略しただけの事実が「消してよい」と名乗ることはない
  /// （既定値を第 2 の判断点にしない）。
  init(
    path: String, branch: String? = nil, head: String = "", isMain: Bool = false,
    isPrunable: Bool = false, lockReason: String? = nil, upstream: String? = nil,
    track: String? = nil, closedPR: DispatchCleanPR? = nil, openPR: Int? = nil,
    status: GitWorktreeStatusCounts? = nil, unmergedCommits: Int? = nil,
    operation: GitWorktreeOperationState = .unknown, occupancy: PaneOccupancy? = nil
  ) {
    self.path = path
    self.branch = branch
    self.head = head
    self.isMain = isMain
    self.isPrunable = isPrunable
    self.lockReason = lockReason
    self.upstream = upstream
    self.track = track
    self.closedPR = closedPR
    self.openPR = openPR
    self.status = status
    self.unmergedCommits = unmergedCommits
    self.operation = operation
    self.occupancy = occupancy
  }

  /// upstream がリモートで消えている。
  var isGone: Bool { track == "[gone]" }
}

/// 分類レーンが 1 worktree について実測した事実。
struct DispatchCleanProbe: Equatable {
  /// `status --porcelain` の件数。nil で判定できなかった（clean を名乗らせない）。
  var status: GitWorktreeStatusCounts?
  /// 取り込み済みなら 0、未取り込みなら独自コミット件数、判定できなければ nil。
  var unmergedCommits: Int?
  /// 停止している git 操作。prunable 行は検知そのものを省くので `.unknown` のまま残る。
  var operation: GitWorktreeOperationState = .unknown
}
