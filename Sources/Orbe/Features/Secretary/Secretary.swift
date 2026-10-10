import Foundation

/// 秘書の係が窓に頼むこと。秘書の会話は Home のタブに住む。
protocol SecretaryHost: AnyObject {
  /// 起動中のタブ（休眠を含む）。閉じていれば nil。
  func secretaryTab(_ id: Int) -> TerminalTab?
  /// その会話を持つタブ（生きているものを休眠より優先）。
  func secretaryTab(session: String) -> TerminalTab?
  /// 検出済みの claude。
  var secretaryClaude: AgentCLI? { get }
  /// Home に新しいタブで `command` を選ばずに起こす。起こせなければ nil。
  func secretaryOpen(command: String) -> TerminalTab?
  /// 休眠のタブを選ばずに起こす（起こす時点で再開が走る）。
  func secretaryWake(_ tab: TerminalTab)
}

/// 秘書の係（窓に 1 つ）。秘書 = 秘書のタブの claude の会話。人の頼みを受けて溜め（`secretary.json` へ即保存）、
/// 秘書のタブを探し・起こし、手が空いたら 1 件ずつ貼り付けて Enter で届ける。
///
/// - 秘書のタブ: 起こしたタブ、または覚えた会話 ID で見つけたタブを、閉じるまで覚える（タブ ID はメモリだけ）。会話 ID は
///   そのタブが報告するたびに書き直し、再起動の後に見つける鍵にだけ使う——/clear で会話が替わっても秘書を見失わない。
/// - 起こすのは頼まれたときと Orbe の起動時（溜めがあるとき）だけ。3 通りとも選ばずに、秘書の役割の指示を添えて起こす:
///   覚えた会話が無ければ新しい claude、あってタブが無ければ新しいタブで再開、休眠のタブがあればそれを起こす。
/// - 届けるのは手が空いた秘書のタブ（idle / done で、送った後なら送った時刻より後に状態が変わった）に 1 件ずつ。
///   起こした直後も、最初の idle を待ってから貼る——届け方を 1 通りにして、「送った後の done / idle まで次を送らない」を
///   1 つの規則で守る。
/// - 覚えた会話で起こしたタブが会話を報告しないまま閉じたら、その会話はもう再開できないとみなして外し、溜めがあれば
///   新しい claude で 1 度だけ起こし直す。新しく起こしたタブが同じく閉じても起こし直さない（溜めは次に頼んだときへ）。
final class Secretary {
  /// 頼みの受け付けの結果。
  enum Acceptance: Equatable {
    /// 受けた（届けたか、秘書が起きるのを待っている）。
    case accepted
    /// 受けたが、秘書が作業中・入力待ちか先に溜めがあるので、手が空いたら届く。
    case queued
  }

  /// 頼みを受けられない理由。
  enum Refusal: Error, Equatable {
    case claudeMissing
    /// 頼めるものが無い（頼んだタスクが消えた・本文が空）。
    case nothingToAsk
  }

  /// 秘書のタブを覚えた経緯。
  private enum Origin {
    /// 新しい claude を起こした。
    case fresh
    /// 覚えた会話で起こした（新しいタブで再開・休眠のタブを起こした）。
    case resumed
    /// 起きているタブを見つけた。
    case found
  }

  private struct Remembered {
    let tabId: Int
    var origin: Origin
    /// 会話を報告した（状態の報告と会話 ID を持った）ことがある。
    var reported: Bool
  }

  private(set) var record: SecretaryFile
  private weak var host: SecretaryHost?
  private let tasks: TaskStore
  private let localization: LocalizationStore
  private var remembered: Remembered?
  /// 最後に貼った時刻。秘書のタブが替われば消える。
  private var sentAt: Date?

  init(
    tasks: TaskStore, localization: LocalizationStore,
    file: SecretaryFile? = SecretaryPersistence.load()
  ) {
    self.tasks = tasks
    self.localization = localization
    record = file ?? .empty
  }

  func attach(_ host: SecretaryHost) {
    self.host = host
  }

  /// 頼みを受けて溜め、起こしてよい一巡を回す。
  func ask(_ ask: SecretaryAsk, now: Date = Date()) throws(Refusal) -> Acceptance {
    guard host?.secretaryClaude != nil else { throw .claudeMissing }
    let task: TaskItem?
    if case .task(let id, _) = ask {
      task = tasks.tasks.first { $0.id == id }
    } else {
      task = nil
    }
    guard let body = SecretaryText.body(ask, task: task, l10n: localization) else {
      throw .nothingToAsk
    }
    let busy = !record.pending.isEmpty || isWorking
    record.pending.append(SecretaryRequest(id: UUID(), receivedAt: now, body: body))
    save()
    cycle(mayLaunch: true)
    return busy && !record.pending.isEmpty ? .queued : .accepted
  }

  /// Orbe の起動時（agent の検出が済んだ後）。溜めがあれば起こしてよい一巡を回す。
  func resumeAtLaunch() {
    guard !record.pending.isEmpty else { return }
    cycle(mayLaunch: true)
  }

  /// その会話が秘書の会話なら、claude の起動に添える秘書の役割の指示（休眠のタブの再開・新しいタブ）。
  func launchArguments(for session: AgentSession) -> [String] {
    guard session.command == "claude", let id = session.sessionId, id == record.sessionId else {
      return []
    }
    return launchArguments
  }

  private var launchArguments: [String] {
    ["--append-system-prompt", SecretaryText.instructions(localization.language)]
  }

  /// 係の一巡（chrome の合流点からは起こさずに）。秘書のタブを探し直し、会話 ID を書き直し、手が空いていれば 1 件
  /// 届ける。`mayLaunch` のときだけ、溜めがあれば秘書を起こす。
  func cycle(mayLaunch: Bool) {
    guard let host else { return }
    forgetClosedTab(host)
    if remembered == nil, let id = record.sessionId, let found = host.secretaryTab(session: id) {
      remember(found, origin: .found)
    }
    if let remembered, let tab = host.secretaryTab(remembered.tabId) { follow(tab) }
    if mayLaunch, !record.pending.isEmpty { launch(host) }
    deliver(host)
  }

  /// 覚えていたタブが閉じていれば忘れる。覚えた会話で起こしたタブが会話を報告しないまま閉じたなら、その会話は
  /// もう再開できない。
  private func forgetClosedTab(_ host: SecretaryHost) {
    guard let closed = remembered, host.secretaryTab(closed.tabId) == nil else { return }
    remembered = nil
    sentAt = nil
    guard !closed.reported, closed.origin == .resumed else { return }
    record.sessionId = nil
    save()
    guard !record.pending.isEmpty else { return }
    // 合流点の中ではタブを起こさない（タブの増減が chrome の値を書く）。次の turn で起こす。
    DispatchQueue.main.async { [weak self] in
      guard let self, let host = self.host, self.remembered == nil else { return }
      self.open(host, command: self.freshCommand(host))
    }
  }

  /// 秘書のタブの報告を追う。会話を報告していれば覚え、記録と違えば書き直す（/clear の後の新しい会話もそのまま
  /// 秘書の会話になる）。
  private func follow(_ tab: TerminalTab) {
    guard tab.agentReport != nil, let id = tab.agentSlot.session?.sessionId,
      tab.agentSlot.session?.command == "claude"
    else { return }
    remembered?.reported = true
    guard id != record.sessionId, AgentCatalog.isSafeSessionId(id) else { return }
    record.sessionId = id
    save()
  }

  private func launch(_ host: SecretaryHost) {
    if let remembered, let tab = host.secretaryTab(remembered.tabId) {
      guard tab.isDormant else { return }
      self.remembered?.origin = .resumed
      host.secretaryWake(tab)
      return
    }
    if let id = record.sessionId,
      let command = AgentCatalog.resumeCommand(
        forAgent: "claude", sessionId: id, arguments: launchArguments)
    {
      open(host, command: command, origin: .resumed)
    } else {
      open(host, command: freshCommand(host))
    }
  }

  private func freshCommand(_ host: SecretaryHost) -> String? {
    host.secretaryClaude.map { AgentCatalog.startCommand($0, arguments: launchArguments) }
  }

  private func open(_ host: SecretaryHost, command: String?, origin: Origin = .fresh) {
    guard let command, let tab = host.secretaryOpen(command: command) else { return }
    remember(tab, origin: origin)
  }

  private func remember(_ tab: TerminalTab, origin: Origin) {
    remembered = Remembered(tabId: tab.id, origin: origin, reported: false)
    sentAt = nil
    follow(tab)
  }

  /// 手が空いた秘書のタブに 1 件を貼って Enter。印は貼る前に立てる（同じ一巡で 2 件送らない）。
  private func deliver(_ host: SecretaryHost) {
    guard let remembered, let tab = host.secretaryTab(remembered.tabId), isFree(tab),
      let next = record.pending.first
    else { return }
    let now = Date()
    sentAt = now
    record.pending.removeFirst()
    save()
    tab.surface.controlSendText(
      SecretaryText.line(next, now: now, timeZone: .current, l10n: localization))
    tab.surface.controlSendKey(ControlKey.enter)
  }

  /// 手が空いた: 起きていて、会話が前面にいて、idle / done で、送った後ならその後に状態が変わった。
  private func isFree(_ tab: TerminalTab) -> Bool {
    guard !tab.isDormant, tab.surface.surfacePtr != nil, tab.conversationIsForeground,
      let report = tab.agentReport, report.state == "idle" || report.state == "done"
    else { return false }
    return sentAt.map { report.stateChangedAt > $0 } ?? true
  }

  /// 秘書が今の頼みに取り掛かっている（起きていて、手が空いていない）。
  private var isWorking: Bool {
    guard let remembered, let tab = host?.secretaryTab(remembered.tabId), !tab.isDormant,
      tab.agentReport != nil
    else { return false }
    return !isFree(tab)
  }

  private func save() {
    SecretaryPersistence.save(record)
  }
}
