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
  /// tracked の未コミット変更（staged 含む）。
  case uncommitted(Int)
  case untracked(Int)
  /// 停止している git 操作（`rebase` / `merge` / `cherry-pick` / `bisect`）。
  case inProgress(GitWorktreeOperation)
  /// ディスク上に実体が無い。
  case prunable

  // MARK: 軸B — ブランチの行き先
  /// マージ済み PR（`base` はマージ先ブランチ）。gh の主張なので**表示専用**——安全判定には使わない。
  case mergedPR(Int, base: String)
  /// 比較先へ取り込み済み（引数は verdict 由来の実マージ先。「merged → \<target\>」）。
  case mergedInto(String)
  /// コミットが remote 上に在る（到達性の証明が立ったか、upstream と一致している）。
  /// マージされたとまでは主張しない——単に完全 push 済みで未マージでも立つため、
  /// 「merged」を名乗ると偽になり得る。
  case onRemote
  /// upstream より k コミット先行している。
  case remoteAhead(Int)
  case unpushed
  case openPR(Int)
  /// upstream が消えている。
  case gone
  /// 消すと失われうる独自コミット k 件（`GitBranchContainment.unmerged` の `count`。到達不能数と
  /// 各比較先の patch 非等価数の min なので、「既定ブランチに取り込まれていない件数」より
  /// 小さくなりうる）。
  case ownCommits(Int)
  /// 安全確認に使う事実（status／停止中の git 操作／取り込み判定）のどれかを確かめられなかった
  /// （確認群に落ちている理由の可視化。分類は変えない——判定不能を安全と読まない契約は既に
  /// 分類側が持つ）。基本起こらない異常系なので、内訳は持たずチップ 1 枚だけで語る。
  case unverified

  // MARK: 軸C — 使用状況
  case agentWorking
  case agentWaiting
  case tabOpen
  case locked
  case mainWorktree

  var id: String {
    switch self {
    case .uncommitted(let n): return "uncommitted:\(n)"
    case .untracked(let n): return "untracked:\(n)"
    case .inProgress(let op): return "inProgress:\(op.name)"
    case .prunable: return "prunable"
    case .mergedPR(let n, let base): return "mergedPR:\(n):\(base)"
    case .mergedInto(let branch): return "mergedInto:\(branch)"
    case .onRemote: return "onRemote"
    case .remoteAhead(let n): return "remoteAhead:\(n)"
    case .unpushed: return "unpushed"
    case .openPR(let n): return "openPR:\(n)"
    case .gone: return "gone"
    case .ownCommits(let n): return "ownCommits:\(n)"
    case .unverified: return "unverified"
    case .agentWorking: return "agentWorking"
    case .agentWaiting: return "agentWaiting"
    case .tabOpen: return "tabOpen"
    case .locked: return "locked"
    case .mainWorktree: return "mainWorktree"
    }
  }

  var tone: CleanTone {
    switch self {
    case .mergedPR, .mergedInto, .onRemote: return .safe
    case .uncommitted, .untracked, .inProgress, .remoteAhead, .unpushed, .openPR, .ownCommits,
      .locked, .agentWaiting, .unverified:
      return .loss
    case .prunable, .gone, .tabOpen, .mainWorktree:
      return .neutral
    case .agentWorking: return .status
    }
  }

  /// 削除で**実際に失われる対象**を名指す語か（展開サブラインの損失内訳に出す）。
  ///
  /// **トーンとは別の軸**として持つ。`PR #N open` や `locked` は琥珀（`loss`）で描くが、消えるのは PR でも
  /// lock でもない——トーンを損失の判定に流用すると、破壊操作の直前に `locked も消えます` という
  /// 事実と違う一文が出る。`未 push · ローカルのみ` は失われるコミットを `独自コミット N 件` が既に
  /// 名指しているので重ねない。
  var isLoss: Bool {
    switch self {
    case .uncommitted, .untracked, .inProgress, .ownCommits, .remoteAhead: return true
    default: return false
    }
  }

  /// 塗りのあるピルか（false は塗らない素文字）。軸C は `locked` を除いて素文字で、
  /// 使用状況は「ピルを増やす」のではなく群の移動そのものが表す。
  var isPill: Bool {
    switch self {
    case .agentWorking, .agentWaiting, .tabOpen, .mainWorktree:
      return false
    default:
      return true
    }
  }
}

/// clean 画面の 1 行（分類の出力。裏の着地のたびに引き直され、画面へそのまま届く）。
struct CleanRow: Identifiable, Equatable {
  /// worktree の絶対パス（一意）。
  let id: String
  /// パスの末尾要素。
  let name: String
  /// meta 列。**ブランチ名だけ**（パスは list モードが見せる）。detached はパスへ落とす。
  let meta: String
  let branch: String?
  /// 分類した時点の HEAD の oid。ブランチ削除を「この先端のときだけ」に絞るために運ぶ
  /// （確定した時点の判定のままコミットを消さない）。
  let head: String
  let group: CleanGroup
  /// この行の判断に要る事実が揃ったか。**揃うまで選べない**（＝自動チェックもされない）。
  /// 揃っていない行も表示はする——何が待たれているのかが見えないほうが不親切だから。
  let isReady: Bool
  /// この行が事実として名乗った語すべて（軸A + 軸B + 軸C）。
  ///
  /// 右クラスタとサブラインは**すべてここからの分配**で、`chips` / `lossNotes` / `overflowNotes` の
  /// どれにも入らない語を作らない。「立った事実が画面から消えていない」をテストが分類器の出力だけで
  /// 主張できるようにするための、行が自分で持つ台帳。
  let vocabulary: [CleanChip]
  /// 右クラスタ（ピルは最大 2 枚、その後に素文字）。**状態（3 軸の事実）だけを語る**——
  /// 動作の予告は安全群の見出しとフッタの実行ボタンが持つ。
  let chips: [CleanChip]
  /// 展開サブラインへ書く損失の内訳（`isLoss` の語彙すべて。ピルへ出たものも含む）。
  let lossNotes: [CleanChip]
  /// 2 枚の上限に載らなかったピル候補（`lossNotes` が既に言う語は除く）。
  /// 展開サブラインへそのままの見た目で回る。
  ///
  /// **損失の内訳とは別の関心**として持つ。溢れの受け皿を `lossNotes` と兼ねると、
  /// `locked` のように「消えないが読ませたい事実」が右クラスタからも内訳からも落ちる——
  /// `locked` はその行が安全群に入れない理由そのものなので、消えると確認群にいる理由が読めない。
  ///
  /// サブラインは確認群のチェック済み行にしか開かないので、**安全行の溢れは画面に出ない**。
  /// それが許されるのは、安全行に loss の語が 1 つも立たないから——レビュー中の PR を持つ行は
  /// 安全確認で落ち、コミットが世界に残ると確認済みの行は `未 push` / `remote +N` を名乗らない。
  /// 残るのは「コミットが世界に残る」という同じ根拠の言い換え（safe / neutral）に限る——merged PR
  /// チップが立つ行では証明由来の `merged → X` がここへ降りるが、merged PR チップ自体が安全根拠の
  /// 表示として必ずピルに載る（判定には使わない・表示上の根拠としては真の主張。台帳 逸脱 18 / 20。
  /// `testSafeRowsRaiseNoLoss` が固定する）。
  let overflowNotes: [CleanChip]
  /// チェックするとブランチも一緒に消える行（safe 群のうち、実体があってブランチを持つ行）。
  let deletesBranchImplicitly: Bool

  /// 展開サブライン（＝**この行の詳細**）を開けるか。開けない行に `lossNotes` / `overflowNotes` を
  /// 積んでも、それは画面に出ない語になる。
  ///
  /// 確認群だけが開く（安全行は選ぶものが無く、使用中行はチェックできない）。**ブランチの扱いの
  /// セグメントは詳細の中身の 1 つに過ぎない**ので、detached（`branch == nil`）でも書くことが
  /// あれば開く——rebase 停止中の worktree は必ず detached で、そこは損失の内訳が最も要る行。
  var canExpandSubline: Bool {
    group == .caution && (branch != nil || !lossNotes.isEmpty || !overflowNotes.isEmpty)
  }
}

/// タブが開いているディレクトリのスナップショット（`SessionStore` を Dispatch から見せないための値型）。
struct TabOccupancy: Equatable {
  /// タブの実効 cwd。
  let cwd: String
  /// agent の状態（`working` / `waiting` / `done` / `idle`）。素のシェルなら nil。
  let agentState: String?
}

/// 紐づく closed PR（掃除の推定と caution の理由に使う）。
struct DispatchCleanPR: Equatable {
  let number: Int
  let isMerged: Bool
  /// マージ先ブランチ（`GitHubBranchPR.baseRefName`）。`.mergedPR` チップの表示にだけ使う。
  let base: String
}

/// ブランチ PR 取得の状態。**「取得中」「取得失敗」「確かめて分かった」を 1 つの値で区別する**
/// ——潰すと、確認前の状態が「レビュー中でない」を名乗って安全確認を素通りする。
enum BranchPRState: Equatable {
  /// 取得中（この行はまだ選べない）。
  case fetching
  /// 確かめられた（`[]` は「紐づく PR は無い」。gh が使えないリポジトリもここ——確認対象が無い）。
  case loaded([GitHubBranchPR])
  /// 取得に失敗した（安全と読まず、確認群で「情報取得に失敗」を見せたうえで手動選択させる）。
  case failed
}

/// レビュー中の PR。「無い」と「まだ分からない」を 1 つの値に潰すと、確認前の状態が安全確認を
/// 素通りするので、4 つを別の case で持つ。
enum CleanOpenPR: Equatable {
  /// まだ確かめていない（取得中）。
  case pending
  /// 確かめられなかった（取得失敗）。
  case unverified
  /// 確かめて、紐づく open PR は無い。
  case none
  case open(Int)
}

/// 分類の入力 1 件。git / gh / タブ走査から採った事実と、その事実がまだ動いているか
/// （`isProbing` / `openPR` の未着地）だけを持ち、subprocess には依存しない。
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
  /// ブランチに紐づく open PR。
  let openPR: CleanOpenPR
  /// `status --porcelain` の件数。nil で判定できなかった。
  let status: GitWorktreeStatusCounts?
  /// 消してコミットが世界に残るかの判定結果。nil で判定できなかった。
  let containment: GitBranchContainment?
  /// 停止している git 操作。
  let operation: GitWorktreeOperationState
  /// このパスを開いているタブ（複数あれば状態を 1 つに畳んだもの）。
  let occupancy: TabOccupancy?
  /// この path のプローブがまだ飛んでいる（status・取り込み判定・停止中の操作が未着地）。
  let isProbing: Bool

  /// 既定値は**すべて安全側**に置く。`containment`（nil）と `operation`（`.unknown`）は
  /// 「判定できなかった」、`openPR`（`.pending`）は「まだ確かめていない」を意味し、省略しただけの
  /// 事実が「消してよい」と名乗ることはない（既定値を第 2 の判断点にしない）。
  init(
    path: String, branch: String? = nil, head: String = "", isMain: Bool = false,
    isPrunable: Bool = false, lockReason: String? = nil, upstream: String? = nil,
    track: String? = nil, closedPR: DispatchCleanPR? = nil, openPR: CleanOpenPR = .pending,
    status: GitWorktreeStatusCounts? = nil, containment: GitBranchContainment? = nil,
    operation: GitWorktreeOperationState = .unknown, occupancy: TabOccupancy? = nil,
    isProbing: Bool = false
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
    self.containment = containment
    self.operation = operation
    self.occupancy = occupancy
    self.isProbing = isProbing
  }

  /// upstream がリモートで消えている。
  var isGone: Bool { track == "[gone]" }
}

/// 分類レーンが 1 worktree について実測した事実。
struct DispatchCleanProbe: Equatable {
  /// `status --porcelain` の件数。nil で判定できなかった（clean を名乗らせない）。
  var status: GitWorktreeStatusCounts?
  /// 消してコミットが世界に残るかの判定結果。判定できなければ nil（safe を名乗らせない）。
  var containment: GitBranchContainment?
  /// 停止している git 操作。prunable 行は検知そのものを省くので `.unknown` のまま残る。
  var operation: GitWorktreeOperationState = .unknown
}
