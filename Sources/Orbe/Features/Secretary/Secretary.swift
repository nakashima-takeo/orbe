import Foundation

/// 秘書の係が窓に頼むこと。秘書の会話は Home のタブに住む。
protocol SecretaryHost: AnyObject {
  /// 起動中のタブ（休眠を含む）。閉じていれば nil。
  func secretaryTab(_ id: Int) -> TerminalTab?
  /// その会話を持つ休眠のタブ。
  func secretaryDormantTab(session: String) -> TerminalTab?
  /// 検出済みの claude。
  var secretaryClaude: AgentCLI? { get }
  /// Home に新しいタブで `command` を選ばずに起こす。起こせなければ nil。
  func secretaryOpen(command: String) -> TerminalTab?
  /// Home に新しいタブでその会話を選ばずに再開する（休眠のタブの起床と同じ組み立てを通る）。
  func secretaryResume(_ session: AgentSession)
  /// 休眠のタブを選ばずに起こす（起こす時点で再開が走る）。
  func secretaryWake(_ tab: TerminalTab)
  /// 秘書が応えない（起こした後の最初の報告・貼った頼みの確証が来ない）ことを、秘書のタブを指す知らせで人に伝える。
  func secretaryUnresponsive(_ tab: TerminalTab)
}

/// 秘書の係（窓に 1 つ）。秘書 = Orbe が秘書として起こした claude のプロセス（そのタブ）。人の頼みを受けて溜め
/// （`secretary.json` へ即保存）、秘書のタブを探し・起こし、手が空いたら 1 件ずつ貼り付けて Enter で届ける。
///
/// - 秘書のタブ: 新しい claude を起こしたタブと、秘書の会話を再開したタブ（係の再開・休眠のタブの起床・続きから・
///   `resume_agent`。どれも休眠のタブの起床の組み立てを通り、そこで秘書の役割の指示を添えて覚える）。タブを閉じる
///   （プロセスが終わればタブも閉じる）まで覚える（タブ ID はメモリだけ）。人がシェルで手で再開した同じ会話のタブは
///   秘書と見なさない。起動直後は、覚えた会話 ID で休眠のタブを見つけ、起こすときに秘書として覚える。
/// - 会話 ID: 秘書のタブが報告するたびに書き直す——/clear で会話が替わっても秘書を見失わない。再起動の後に休眠の
///   タブを見つける鍵と、タブが無いときの再開の鍵にだけ使う。
/// - 起こすのは頼まれたときと Orbe の起動時（溜めがあるとき）だけ。3 通りとも選ばずに、秘書の役割の指示を添えて起こす:
///   覚えた会話が無ければ新しい claude、あってタブが無ければ新しいタブで再開、休眠のタブがあればそれを起こす。
/// - 届けるのは手が空いた秘書のタブ（会話へ今貼ってよく、送った後なら送った時刻より後に状態が変わった）に 1 件ずつ。
///   起こした直後も、最初の idle を待ってから貼る——届け方を 1 通りにして、「送った後の done / idle まで次を送らない」を
///   1 つの規則で守る。
/// - 貼った頼みは、その後の working（UserPromptSubmit）の報告を届いた確証として、そこで溜めから外す。確証が無いまま
///   次の状態の変化が来たら同じ頼みを送り直す——claude の対話（フォルダの信頼・要約から再開）が出ていると、貼った文字は
///   入力欄に届かない。起こしてから最初の報告、貼ってから確証が `patience` の間に来なければ、秘書のタブを指す知らせを出す。
/// - 覚えた会話で起こしたタブが、会話を報告しないまま claude が終わって閉じたら、その会話はもう再開できないとみなして
///   外し、溜めがあれば新しい claude で 1 度だけ起こし直す。新しく起こしたタブが同じく閉じても、人や制御 API が閉じても
///   起こし直さない（溜めは次に頼んだときへ）。
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
    /// 覚えた会話を再開した。
    case resumed
    /// 覚えた会話の休眠のタブを見つけた（まだ起きていない）。
    case found
  }

  private struct Remembered {
    let tabId: Int
    let origin: Origin
    /// 会話を報告した（状態の報告と会話 ID を持った）ことがある。
    var reported: Bool
    /// 閉じ方（閉じたときだけ）。
    var closedBy: TabCloseOrigin?
  }

  private(set) var record: SecretaryFile
  private weak var host: SecretaryHost?
  private let tasks: TaskStore
  private let localization: LocalizationStore
  private var remembered: Remembered?
  /// 最後に貼った時刻。秘書のタブが替われば消える。
  private var sentAt: Date?
  /// 貼ったが、まだ届いた確証の無い頼み。
  private var unconfirmed: UUID?
  /// 応えを待つ見張りの世代。新しい見張りが前の見張りを無効にする。
  private var watchGeneration = 0
  /// 秘書が応えないとみなすまでの時間（起こしてから最初の報告・貼ってから確証まで）。
  var patience: TimeInterval = 30

  init(
    host: SecretaryHost, tasks: TaskStore, localization: LocalizationStore,
    file: SecretaryFile? = SecretaryPersistence.load()
  ) {
    self.host = host
    self.tasks = tasks
    self.localization = localization
    record = file ?? .empty
  }

  /// 秘書のタブ（覚えていれば）。
  var tabId: Int? { remembered?.tabId }

  /// そのタブが今の秘書か（起きている秘書のタブ）。
  func isSecretary(_ tab: TerminalTab) -> Bool {
    remembered?.tabId == tab.id && !tab.isDormant
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
    record.pending.append(
      SecretaryRequest(id: UUID(), receivedAt: now, origin: ask.origin, body: body))
    save()
    cycle(mayLaunch: true)
    return busy && !record.pending.isEmpty ? .queued : .accepted
  }

  /// Orbe の起動時（agent の検出が済んだ後）。溜めがあれば起こしてよい一巡を回す。
  func resumeAtLaunch() {
    guard !record.pending.isEmpty else { return }
    cycle(mayLaunch: true)
  }

  /// 会話をタブで再開する直前（休眠のタブの起床の組み立て）。秘書の会話なら、そのタブを秘書として覚え、claude の起動に
  /// 添える秘書の役割の指示を返す。
  func launching(_ session: AgentSession, in tab: TerminalTab) -> [String] {
    guard session.command == "claude", let id = session.sessionId, id == record.sessionId else {
      return []
    }
    remember(tab, origin: .resumed)
    return launchArguments
  }

  /// タブを閉じる直前（閉じ方を覚える。覚えた会話が再開できないとみなすのは claude が終わって閉じたときだけ）。
  func tabClosing(_ id: Int, origin: TabCloseOrigin) {
    guard remembered?.tabId == id else { return }
    remembered?.closedBy = origin
  }

  /// 秘書のタブの報告（合流点を待たずに、届いた直後に）。貼った頼みの後に作業を始めた（working）なら、届いた確証として
  /// 溜めから外す。合流点で見ると、すぐ終わるターンの working を見逃して同じ頼みを送り直す。
  func noteReport(from tab: TerminalTab) {
    guard remembered?.tabId == tab.id, let id = unconfirmed, let sentAt,
      let report = tab.agentReport, report.state == "working", report.stateChangedAt > sentAt
    else { return }
    unconfirmed = nil
    record.pending.removeAll { $0.id == id }
    save()
  }

  private var launchArguments: [String] {
    ["--append-system-prompt", SecretaryText.instructions(localization.language)]
  }

  /// 係の一巡（chrome の合流点からは起こさずに）。秘書のタブを探し直し、会話 ID を書き直し、手が空いていれば 1 件
  /// 届ける。`mayLaunch` のときだけ、溜めがあれば秘書を起こす。
  func cycle(mayLaunch: Bool) {
    guard let host else { return }
    forgetClosedTab(host)
    if remembered == nil, let id = record.sessionId,
      let found = host.secretaryDormantTab(session: id)
    {
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
    unconfirmed = nil
    guard !closed.reported, closed.origin == .resumed, closed.closedBy == .process else { return }
    record.sessionId = nil
    save()
    guard !record.pending.isEmpty else { return }
    // 合流点の中ではタブを起こさない（タブの増減が chrome の値を書く）。次の turn で起こす。
    DispatchQueue.main.async { [weak self] in self?.cycle(mayLaunch: true) }
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

  /// 秘書を起こす。再開の 2 通り（休眠のタブ・新しいタブ）は休眠のタブの起床を通り、そこで秘書として覚える
  /// （`launching`）。
  private func launch(_ host: SecretaryHost) {
    if let remembered, let tab = host.secretaryTab(remembered.tabId) {
      if tab.isDormant { host.secretaryWake(tab) }
      return
    }
    if let id = record.sessionId {
      host.secretaryResume(AgentSession(command: "claude", sessionId: id))
    } else if let claude = host.secretaryClaude,
      let tab = host.secretaryOpen(
        command: AgentCatalog.startCommand(claude, arguments: launchArguments))
    {
      remember(tab, origin: .fresh)
    }
  }

  private func remember(_ tab: TerminalTab, origin: Origin) {
    remembered = Remembered(tabId: tab.id, origin: origin, reported: false)
    sentAt = nil
    unconfirmed = nil
    follow(tab)
    if origin != .found { watch { $0.agentReport == nil } }
  }

  /// 手が空いた秘書のタブに 1 件を貼って Enter。印は貼る前に立てる（同じ一巡で 2 件送らない）。溜めから外すのは
  /// 届いた確証を見てから（`noteReport`）。
  private func deliver(_ host: SecretaryHost) {
    guard let remembered, let tab = host.secretaryTab(remembered.tabId), isFree(tab),
      let next = record.pending.first
    else { return }
    let now = Date()
    sentAt = now
    unconfirmed = next.id
    tab.surface.controlSendText(
      SecretaryText.line(next, now: now, timeZone: .current, l10n: localization))
    tab.surface.controlSendKey(ControlKey.enter)
    watch { [weak self] _ in self?.unconfirmed == next.id && self?.sentAt == now }
  }

  /// `patience` の後も秘書のタブが `silent` なら、人に知らせる。
  private func watch(_ silent: @escaping (TerminalTab) -> Bool) {
    watchGeneration += 1
    let generation = watchGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + patience) { [weak self] in
      guard let self, generation == self.watchGeneration, let host = self.host,
        let id = self.remembered?.tabId, let tab = host.secretaryTab(id), !tab.isDormant,
        silent(tab)
      else { return }
      host.secretaryUnresponsive(tab)
    }
  }

  /// 手が空いた: 会話へ今貼ってよく（`TerminalTab.acceptsConversationInput`）、送った後ならその後に状態が変わった。
  private func isFree(_ tab: TerminalTab) -> Bool {
    guard tab.acceptsConversationInput, let report = tab.agentReport else { return false }
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
