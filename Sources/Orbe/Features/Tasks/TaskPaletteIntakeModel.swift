import Foundation
import Observation

/// 受信タブで居る場所。→ が一段深く、← が一段浅い（棚 ← 提案の一覧 → 中身）。
enum TaskPaletteIntakePlace: Equatable {
  /// 提案の一覧（入力欄に焦点）。
  case proposals
  /// 左の棚（カードの器に焦点）。
  case shelf
  /// 棚で選んだ受信の中身（カードの器に焦点）。どの受信かは棚の選択が持つ。
  case contents
}

/// 棚の段の同一性。
enum TaskPaletteIntakeShelfID: Hashable {
  case all
  case intake(Int)
}

/// 棚の段。`intake` が nil なら「すべて」。
struct TaskPaletteIntakeShelfRow: Equatable, Identifiable {
  let id: TaskPaletteIntakeShelfID
  let intake: Intake?
  /// 棚に出ている人の判断待ちの提案の数。
  let count: Int
}

/// 受信タブの失敗（フッターに赤で出す）。
enum TaskPaletteIntakeError: Equatable {
  /// タスクにするを、タスクのストアが受け付けなかった。
  case accept
  /// 走っている間の今すぐ受信。
  case running
}

/// ⌘⇧X の受信タブの状態（@Observable）。受信・提案・回の記録は受信のストアから、走っているか・次の時刻は走らせ役から
/// 毎回読み、写さない。ここが持つのは棚と提案の一覧の状態（入力・同一性での選択）・居場所・失敗だけ。
/// ストアが変わったら `reconcile()` で選択と居場所を付け直す（カードの `.onChange` が届ける）。
@Observable final class TaskPaletteIntakeModel {
  let runner: IntakeRunner
  let tasks: TaskStore
  /// 提案をタスクにすると付く workspace（開いた時点の Home）。
  let home: UUID?
  let today: TaskItem.DueDate
  let timeZone: TimeZone

  private(set) var shelfList = TaskPaletteListState<TaskPaletteIntakeShelfID>()
  private(set) var proposalList = TaskPaletteListState<Int>()
  private(set) var place: TaskPaletteIntakePlace = .proposals {
    didSet { if place != oldValue { onPlaceChange() } }
  }
  private(set) var error: TaskPaletteIntakeError?

  /// 居場所が変わった（焦点の行き先が入力欄とカードの器の間で移る）。
  @ObservationIgnored var onPlaceChange: () -> Void = {}
  /// 提案をタスクにする位置（タスクのタブの範囲で見ている欄。`TaskPaletteModel.addPosition`）。
  @ObservationIgnored var addPosition: () -> TaskStore.AddPosition = { .end }
  @ObservationIgnored var onOpenURL: (URL) -> Void = { _ in }

  init(
    runner: IntakeRunner, tasks: TaskStore, home: UUID?, today: TaskItem.DueDate,
    timeZone: TimeZone
  ) {
    self.runner = runner
    self.tasks = tasks
    self.home = home
    self.today = today
    self.timeZone = timeZone
    reconcile()
  }

  var store: IntakeStore { runner.store }

  // MARK: - 行

  /// 人の判断待ちの提案と、それを出す棚の受信。
  private var shelved: [(proposal: IntakeProposal, shelf: Int)] {
    store.proposals.compactMap { proposal in
      guard proposal.state == .open, let shelf = store.shelf(of: proposal) else { return nil }
      return (proposal, shelf.id)
    }
  }

  /// ヘッダーのタブの件数（入力の絞り込みに左右されない）。
  var openCount: Int { shelved.count }

  /// 「すべて」と、受信を ID 順に。
  var shelfRows: [TaskPaletteIntakeShelfRow] {
    let counts = Dictionary(grouping: shelved, by: \.shelf).mapValues(\.count)
    return [TaskPaletteIntakeShelfRow(id: .all, intake: nil, count: shelved.count)]
      + store.intakes.sorted { $0.id < $1.id }.map {
        TaskPaletteIntakeShelfRow(id: .intake($0.id), intake: $0, count: counts[$0.id] ?? 0)
      }
  }

  var shelfIDs: [TaskPaletteIntakeShelfID] { shelfRows.map(\.id) }

  /// 棚の選択で絞り、入力（タイトルか本文の部分一致）で絞った提案。提案した回の新しい順、同じ回の中は判定の出力順。
  var proposals: [IntakeProposal] {
    let query = proposalList.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = shelfList.selectedID
    return shelved.filter { entry in
      switch selected {
      case .intake(let id): return entry.shelf == id
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

  var selectedIntake: Intake? {
    guard case .intake(let id) = shelfList.selectedID else { return nil }
    return store.intake(id)
  }

  var selectedProposal: IntakeProposal? {
    guard let id = proposalList.selectedID else { return nil }
    return store.proposals.first { $0.id == id && $0.state == .open }
  }

  func isRunning(_ intake: Intake) -> Bool { runner.isRunning(intake.id) }

  func nextRunAt(_ intake: Intake) -> Date? { runner.nextRunAt(intake) }

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

  /// ストアが変わったあとの付け直し。どちらの一覧も同一性で選び直し、消えたら同じ位置へ移る。中身に居る間に棚の選択の
  /// 同一性が変わった（受信が消えた）ら、提案の一覧へ戻る。
  func reconcile() {
    let shelf = shelfList.selectedID
    shelfList.reconcile(shelfIDs)
    proposalList.reconcile(proposalIDs)
    if place == .contents, shelfList.selectedID != shelf || selectedIntake == nil {
      place = .proposals
    }
  }

  func moveProposal(_ direction: Int) {
    error = nil
    proposalList.move(direction, in: proposalIDs)
  }

  func jumpProposal(_ direction: Int) {
    error = nil
    proposalList.jump(direction, in: proposalIDs)
  }

  func moveShelf(_ direction: Int) {
    error = nil
    shelfList.move(direction, in: shelfIDs)
    proposalList.selectFirst(in: proposalIDs)
  }

  func jumpShelf(_ direction: Int) {
    error = nil
    shelfList.jump(direction, in: shelfIDs)
    proposalList.selectFirst(in: proposalIDs)
  }

  /// 棚の段のクリック。選んで提案の一覧に居る。
  func tapShelf(_ id: TaskPaletteIntakeShelfID) {
    error = nil
    place = .proposals
    guard shelfList.selectedID != id, shelfList.select(id, in: shelfIDs) else { return }
    proposalList.selectFirst(in: proposalIDs)
  }

  func tapProposal(_ id: Int) {
    error = nil
    place = .proposals
    proposalList.select(id, in: proposalIDs)
  }

  /// ホバーの追従は、その一覧に居る間だけ効く。
  func hoverShelf(_ id: TaskPaletteIntakeShelfID) {
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

  func enterShelf() {
    error = nil
    place = .shelf
  }

  func showProposals() {
    error = nil
    place = .proposals
  }

  /// 受信を選んでいるときだけ（「すべて」の中身は無い）。
  func enterContents() {
    guard selectedIntake != nil else { return }
    error = nil
    place = .contents
  }

  // MARK: - 提案をさばく

  /// ↵。選んでいる提案を Home のタスクにする。判定の確定や下げと行き違っただけなら何も出さず、付け直しに任せる。
  func accept() {
    guard let proposal = selectedProposal else { return }
    error = nil
    do throws(IntakeError) {
      _ = try store.accept(
        proposal.id, into: tasks, workspace: home, at: addPosition())
    } catch {
      if case .invalid = error { self.error = .accept }
    }
    settle()
  }

  /// ⌘⌫。選んでいる提案を捨てる。
  func dismiss() {
    guard let proposal = selectedProposal else { return }
    error = nil
    try? store.dismiss(proposal.id)
    settle()
  }

  /// ⌘↵・リンクのクリック。
  func openLink() {
    guard let proposal = selectedProposal, let url = URL(string: proposal.item.link) else { return }
    onOpenURL(url)
  }

  private func settle() {
    reconcile()
    proposalList.follow()
  }

  // MARK: - 受信の中身

  func runNow() {
    guard let intake = selectedIntake else { return }
    error = nil
    do throws(IntakeError) {
      try runner.runNow(intake.id)
    } catch {
      if case .running = error { self.error = .running }
    }
  }

  /// space。止める ⇄ 再開。
  func togglePause() {
    guard let intake = selectedIntake else { return }
    error = nil
    _ = try? runner.pause(intake.id, !intake.paused)
  }

  /// ⌘⌫。確認なしで消し、提案の一覧へ戻る。棚は同じ位置の段を選ぶ。
  func deleteIntake() {
    guard let intake = selectedIntake else { return }
    error = nil
    try? runner.delete(intake.id)
    reconcile()
    place = .proposals
    proposalList.selectFirst(in: proposalIDs)
  }
}
