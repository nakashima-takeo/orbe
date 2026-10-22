import Foundation
import Observation

/// 提案タブで居る場所。候補が選ばれているのは候補の一覧に居る間だけ。
enum TaskPaletteAutomationPlace: Equatable {
  /// 絞り込み欄（開いた直後。入力欄に焦点）。
  case field
  /// 左の棚（カードの器に焦点）。
  case shelf
  /// 候補の一覧（入力欄に焦点）。
  case proposals
}

/// 棚の段の同一性。
enum TaskPaletteAutomationShelfID: Hashable {
  case all
  case automation(Int)
}

/// 棚の段。`automation` が nil なら「すべて」。
struct TaskPaletteAutomationShelfRow: Equatable, Identifiable {
  let id: TaskPaletteAutomationShelfID
  let automation: Automation?
  /// 棚に出ている人の判断待ちの提案の数。
  let count: Int
}

/// 棚の段の 2 行目。左に前回の判定、右に今の状態。ビューは文言と色だけを決める。
struct TaskPaletteAutomationShelfStatus: Equatable {
  /// 最も新しく回った判定の部品の最新の回。まだどの判定も回っていなければ nil。
  let last: Judged?
  let state: State?

  struct Judged: Equatable {
    let at: Date
    let failed: Bool
  }

  enum State: Equatable {
    /// 候補を更新している一巡の間。
    case refreshing
    case paused
  }
}

/// 提案タブの失敗（フッターに赤で出す）。
enum TaskPaletteAutomationError: Equatable {
  /// タスクにするを、タスクのストアが受け付けなかった。
  case accept
  /// 候補の更新を、一巡の途中なので断った。
  case refreshing

  var message: L10nKey {
    switch self {
    case .accept: .taskPaletteAutomationErrAccept
    case .refreshing: .taskPaletteAutomationErrRefreshing
    }
  }
}

/// ⌘⇧X の提案タブの状態（@Observable）。自動化・候補・回の記録はストアから、一巡の有無・次の時刻は走らせ役から毎回読み、
/// 写さない。ここが持つのは棚と候補の一覧の状態（入力・同一性での選択）・居場所・失敗だけ。候補の一覧の選択は覚えている行で、
/// それが「選ばれている」のは候補の一覧に居る間だけ（印・詳細・さばく操作はすべて `selectedProposal` を読む）。
/// ストアが変わったら `reconcile()` で選択を付け直す（カードの `.onChange` が届ける）。
@Observable final class TaskPaletteAutomationModel {
  let runner: AutomationRunner
  let tasks: TaskStore
  /// 今の workspace の値。候補の付け先は表示も受理もこれで解く——開いた時点の写しで受理すると、開いている間に消えた
  /// 付け先へ付けてしまう。
  let workspaces: () -> TaskPaletteWorkspaces
  let today: TaskItem.DueDate
  let timeZone: TimeZone

  private(set) var shelfList = ListState<TaskPaletteAutomationShelfID>()
  private(set) var proposalList = ListState<Int>()
  private(set) var place: TaskPaletteAutomationPlace = .field {
    didSet { if place != oldValue { onPlaceChange() } }
  }
  private(set) var error: TaskPaletteAutomationError?

  /// 失敗を消す（タブを替えるなど、提案タブの外の操作の境目）。
  func clearError() {
    error = nil
  }

  /// 居場所が変わった（焦点の行き先が入力欄とカードの器の間で移りうる）。
  @ObservationIgnored var onPlaceChange: () -> Void = {}
  @ObservationIgnored var onOpenURL: (URL) -> Void = { _ in }
  /// そのタスクのための agent を開く口（タスクの ID）。
  @ObservationIgnored var onOpenTask: (Int) -> Void = { _ in }

  init(
    runner: AutomationRunner, tasks: TaskStore, workspaces: @escaping () -> TaskPaletteWorkspaces,
    today: TaskItem.DueDate, timeZone: TimeZone
  ) {
    self.runner = runner
    self.tasks = tasks
    self.workspaces = workspaces
    self.today = today
    self.timeZone = timeZone
    reconcile()
  }

  var store: AutomationStore { runner.store }

  // MARK: - 行

  /// 人の判断待ちの提案と、それを出す棚の受信。
  private var shelved: [(proposal: AutomationProposal, shelf: Int)] { store.shelvedProposals }

  /// ヘッダーのタブの件数（入力の絞り込みに左右されない）。
  var openCount: Int { shelved.count }

  /// 「すべて」と、判定の部品を持つ自動化を ID 順に。
  var shelfRows: [TaskPaletteAutomationShelfRow] {
    let counts = Dictionary(grouping: shelved, by: \.shelf).mapValues(\.count)
    return [TaskPaletteAutomationShelfRow(id: .all, automation: nil, count: shelved.count)]
      + store.automations.filter(\.judges)
      .sorted { $0.id < $1.id }.map {
        TaskPaletteAutomationShelfRow(
          id: .automation($0.id), automation: $0, count: counts[$0.id] ?? 0)
      }
  }

  var shelfIDs: [TaskPaletteAutomationShelfID] { shelfRows.map(\.id) }

  /// 棚の選択で絞り、入力（タイトルか本文の部分一致）で絞った提案。提案した回の新しい順、同じ回の中は判定の出力順。
  var proposals: [AutomationProposal] {
    let query = proposalList.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = shelfList.selectedID
    return shelved.filter { entry in
      switch selected {
      case .automation(let id): return entry.shelf == id
      case .all, nil: return true
      }
    }
    .map(\.proposal)
    .filter {
      query.isEmpty || $0.title.localizedStandardContains(query)
        || $0.item.body.localizedStandardContains(query)
    }
    .sorted { ($0.proposedAt, -$0.id) > ($1.proposedAt, -$1.id) }
  }

  var proposalIDs: [Int] { proposals.map(\.id) }

  var selectedAutomation: Automation? {
    guard case .automation(let id) = shelfList.selectedID else { return nil }
    return store.automation(id)
  }

  /// 選ばれている候補。候補の一覧に居る間だけ、覚えている行を返す。
  var selectedProposal: AutomationProposal? {
    guard place == .proposals, let id = proposalList.selectedID else { return nil }
    return store.proposals.first { $0.id == id && $0.state == .open }
  }

  /// 候補をタスクにしたときの付け先（今の値で解く）。
  func destination(of proposal: AutomationProposal) -> TaskPaletteWorkspaces.Entry? {
    workspaces().destination(of: proposal.workspace)
  }

  /// 候補の出どころの取得の部品の名前。候補を出した自動化の定義から引き、部品か自動化が消えていれば nil。
  func sourceName(of proposal: AutomationProposal) -> String? {
    proposal.automationId.flatMap { store.automation($0)?.graph.node(proposal.source)?.part.name }
  }

  /// 候補を出した判定の部品の名前。部品か自動化が消えていれば nil。
  func judgeName(of proposal: AutomationProposal) -> String? {
    proposal.automationId.flatMap { store.automation($0)?.graph.node(proposal.judge)?.part.name }
  }

  /// 棚の段の 2 行目。前回の判定は、判定の部品のうち最も新しく回ったものの最新の回（他の判定の失敗は一覧の頭で見る）。今の
  /// 状態は、一巡の間なら更新中、止めていれば停止中。
  func status(of automation: Automation) -> TaskPaletteAutomationShelfStatus {
    let last = automation.graph.judges.compactMap { automation.state($0.id).runs.first }
      .max { $0.startedAt < $1.startedAt }
    let state: TaskPaletteAutomationShelfStatus.State? =
      runner.isFlowing(automation.id) ? .refreshing : automation.paused ? .paused : nil
    return TaskPaletteAutomationShelfStatus(
      last: last.map { .init(at: $0.startedAt, failed: $0.failed) }, state: state)
  }

  // MARK: - 入力・選択

  var query: String {
    get { proposalList.query }
    set {
      guard newValue != proposalList.query else { return }
      proposalList.query = newValue
      error = nil
      proposalList.selectFirst(in: proposalIDs)
    }
  }

  /// 実マウス移動が `.pointer` へ落とす。
  var modality: InputModality {
    get { proposalList.modality }
    set {
      proposalList.modality = newValue
      shelfList.modality = newValue
    }
  }

  /// ストアが変わったあとの付け直し。どちらの一覧も同一性で選び直し、消えたら同じ位置へ移る。
  func reconcile() {
    shelfList.reconcile(shelfIDs)
    proposalList.reconcile(proposalIDs)
  }

  func moveProposal(_ direction: Int) {
    error = nil
    proposalList.move(direction, in: proposalIDs)
  }

  func jumpProposal(_ direction: Int) {
    error = nil
    proposalList.jump(direction, in: proposalIDs)
  }

  /// 棚は端で巡回しない。先頭の ↑ は絞り込み欄へ戻る。
  func moveShelf(_ direction: Int) {
    error = nil
    let ids = shelfIDs
    guard let index = shelfList.selectedID.flatMap({ ids.firstIndex(of: $0) }) else { return }
    let target = index + direction
    if target < 0 { return enterField() }
    guard target < ids.count else { return }
    shelfList.select(ids[target], in: ids)
    proposalList.selectFirst(in: proposalIDs)
  }

  func jumpShelf(_ direction: Int) {
    error = nil
    let previous = shelfList.selectedID
    shelfList.jump(direction, in: shelfIDs)
    if shelfList.selectedID != previous { proposalList.selectFirst(in: proposalIDs) }
  }

  /// 棚の段のクリック。選んで棚に居る（焦点のある列だけが選ばれているので、候補は選ばれない）。
  func tapShelf(_ id: TaskPaletteAutomationShelfID) {
    error = nil
    place = .shelf
    guard shelfList.selectedID != id, shelfList.select(id, in: shelfIDs) else { return }
    proposalList.selectFirst(in: proposalIDs)
  }

  func tapProposal(_ id: Int) {
    error = nil
    place = .proposals
    proposalList.select(id, in: proposalIDs)
  }

  /// ホバーの追従は、その一覧に居る間だけ効く。
  func hoverShelf(_ id: TaskPaletteAutomationShelfID) {
    guard place == .shelf else { return }
    let previous = shelfList.selectedID
    shelfList.hoverSelect(id, in: shelfIDs)
    if shelfList.selectedID != previous { proposalList.selectFirst(in: proposalIDs) }
  }

  func hoverProposal(_ id: Int) {
    guard place == .proposals else { return }
    proposalList.hoverSelect(id, in: proposalIDs)
  }

  // MARK: - 居場所

  func enterField() {
    error = nil
    place = .field
  }

  func enterShelf() {
    error = nil
    place = .shelf
  }

  /// 覚えている行が選ばれる。
  func enterProposals() {
    error = nil
    place = .proposals
  }

  // MARK: - 提案をさばく

  /// ↵。選んでいる提案を付け先のタスクにする。
  func accept() {
    _ = acceptSelected()
  }

  /// ⌘↵・詳細のボタン。↵ と同じくタスクにして、できたタスクの agent を開く口へ渡す。
  func acceptAndOpen() {
    guard let task = acceptSelected() else { return }
    onOpenTask(task.id)
  }

  /// 選んでいる提案を付け先のタスクにする。判定の確定や下げと行き違っただけなら何も出さず、付け直しに任せる。
  private func acceptSelected() -> TaskItem? {
    guard let proposal = selectedProposal else { return nil }
    error = nil
    var task: TaskItem?
    do throws(AutomationError) {
      task = try store.accept(proposal.id, into: tasks, workspace: destination(of: proposal)?.id)
    } catch {
      if case .invalid = error { self.error = .accept }
    }
    settle()
    return task
  }

  /// ⌘⌫。選んでいる提案を捨てる。
  func dismiss() {
    guard let proposal = selectedProposal else { return }
    error = nil
    try? store.dismiss(proposal.id)
    settle()
  }

  /// ⌘O・リンクのクリック。
  func openLink() {
    guard let proposal = selectedProposal, let url = URL(string: proposal.item.link) else { return }
    onOpenURL(url)
  }

  private func settle() {
    reconcile()
    proposalList.follow()
  }

  // MARK: - 候補の更新

  /// 棚の ⌘↵。選んでいる自動化の候補を今すぐ更新する（タスク候補を行き先にする部品すべてまで流す）。断るのは一巡の途中
  /// だけで、行き違い（消えていた・使えない）は黙る。「すべて」では何もしない。
  func refresh() {
    guard let automation = selectedAutomation else { return }
    error = nil
    do throws(AutomationError) {
      try runner.flow(automation.id, to: .judges)
    } catch {
      if case .flowing = error { self.error = .refreshing }
    }
  }
}
