import AppKit
import GhosttyKit
import OrbeSessionLog

/// タブ 1 枚。端末 surface 1 枚（`SurfaceView`）と「タブとしての状態」——制御チャネルの宛先 ID・
/// エージェントスロット・明示タイトル・復元単位——を所有する。外部から指す単位・エージェントが走る
/// 単位・永続の単位はすべてこのタブで、`SurfaceView` はシェルが報告する事実（タイトル・cwd）と
/// 端末 I/O だけを持つ。
///
/// `view`（`SurfaceScrollView`）は AppKit の NSView として作り直さずに mount / 隠す / 外すだけを行う。
/// SwiftUI に所有させて再生成すると scrollback と非アクティブ workspace の keep-alive
/// （NSView 同一性に依存）を壊す（cf. ghostty-org/ghostty#9444）。
final class TerminalTab {
  /// 制御チャネルの宛先 ID（外部からこのタブを一意に指す）。
  let id = IdGen.next()
  /// mount 単位（ネイティブ overlay スクロールバー付きの surface ラップ）。`WindowController` が
  /// content へ載せる／隠す／外す。
  let view: SurfaceScrollView
  var surface: SurfaceView { view.surfaceView }

  /// このタブが materialize 済み側にある現在状態。現仕様の遷移は false → true のみだが、
  /// 履歴bitではなく、将来の再休眠では false へ戻せる責務として扱う。
  /// 永続化せず、surface 生成の成功可否ではなく window hierarchy への attach 開始時に true とする。
  private(set) var activated = false

  /// このタブを閉じる通知。閉鎖の発火源を添えて渡す（同一性の終わり方としてログに写る）。
  var onClose: ((TabCloseOrigin) -> Void)?
  /// タイトルが変わった通知（タブラベル更新用。再算出は呼び出し側が全タブで行う）。
  var onTitleChange: (() -> Void)?
  /// ウィンドウレベルの chrome 操作を上位へ届ける通知。
  var onWindowCommand: ((WindowCommand) -> Void)?
  /// OSC 7 で cwd が報告された通知（chrome の cwd 表示・永続保存用）。
  var onPwdChange: (() -> Void)?
  /// エージェントスロットが変わった通知（タブのインジケータ・横断ロールアップ更新用）。
  var onAgentStateChange: (() -> Void)?

  /// 同一性（command + sessionId）の寿命の遷移。上位（`WindowController`）が所属 workspace を
  /// 引いてセッションログへ記録する。
  enum IdentityTransition: Equatable {
    /// resume できる同一性を得た（初回報告で sessionId が付いた・休眠チケットが起きた・切替後）。
    case opened(SessionEvent.Agent)
    /// 同一性が終わった。`agent` は報告（clear / sessionId の切替）、`unresolved` は起床で resume を
    /// 解決できなかったとき、残りはタブが store から外れたときの `TabCloseOrigin` の写し。
    case closed(SessionEvent.Agent, origin: SessionEvent.CloseOrigin, reason: String?)
  }
  var onIdentityTransition: ((IdentityTransition) -> Void)?

  /// Cmd+R で付けた明示タイトル（sticky・tab単位）。非nil・非空なら最優先。空入力で nil へ戻す。
  var explicitTitle: String?

  /// このタブの agent スロット（none / dormant / live）。永続しない（休眠チケットの同一性
  /// だけが保存 schema へ写る）。`agent_state` 制御イベントの emit は didSet が一元で担う——
  /// どの遷移経路でも、導出 `agentState` の実変化だけがイベントを流す。chrome の再投影は
  /// スロットの実変化（文言・sessionId の更新を含む）で行う。順序は emit → 通知——通知先の
  /// done 消費が再入して idle を書くとき、履歴が done → idle の順に並ぶ。
  ///
  /// 同一性の遷移を起こすのは `applyReport` / `recordMaterializationStarted` / `recordDetached` の
  /// 3 メソッドだけで、外部からの代入は無い——代入 1 つで寿命ログの記録漏れが起きる形を
  /// コンパイルで防ぐ。
  private(set) var agentSlot: AgentSlot = .none {
    didSet {
      if agentState != oldValue.report?.state {
        ControlServer.shared.emit(
          .agentState(
            tabId: id, state: agentState, message: agentReport?.message?.text,
            sessionId: agentSlot.session?.sessionId))
      }
      if agentSlot != oldValue { onAgentStateChange?() }
    }
  }
  /// 稼働中 agent の最新の自己報告（live 以外は nil）。Attention・rollup の読み口。
  var agentReport: AgentReport? { agentSlot.report }
  /// 報告中の状態文字列（idle/working/waiting/done。報告なしは nil）。タブのインジケータが読む。
  var agentState: String? { agentReport?.state }
  /// 未消費の復元チケット（休眠 agent）を持つか。
  var isDormant: Bool { agentSlot.isDormant }

  /// 実効 cwd（OSC 7 報告前は起動時 cwd＝復元値）。永続・列挙・占有判定・タイトル導出・
  /// 新タブの cwd 継承はすべてこの 1 つの定義を読む。
  var cwd: String { surface.currentPwd ?? surface.initialCwd }

  /// このタブの表示タイトル。① explicitTitle ?? ② アプリ報告タイトル ?? ③ derived(cwd, root)。
  /// rootPath は所属 Workspace が持つため呼び出し側（WindowController）から渡す。
  /// ② は title が非空かつ currentPwd と異なるときだけ採用する。libghostty は明示タイトル
  /// （OSC 2）未受信の間、OSC 7 の生 pwd をタイトルに使う（stream_handler.zig reportPwd）ため、
  /// title == currentPwd は pwd フォールバック＝③の仕事の重複。生 pwd は出さず③で整形する。
  func displayTitle(workspaceRoot: String?) -> String {
    if let e = explicitTitle, !e.isEmpty { return e }
    return derivedTitle(workspaceRoot: workspaceRoot)
  }

  /// explicitTitle を無視した派生タイトル（②③）。インライン改名の field を空にしたときの
  /// 戻り先プレビュー（プレースホルダ）に使う。
  func derivedTitle(workspaceRoot: String?) -> String {
    let title = surface.title
    if !title.isEmpty, title != surface.currentPwd { return title }
    return TabTitle.derive(pwd: cwd, root: workspaceRoot)
  }

  /// 通常タブは cwd だけ。エージェント起動タブは起動コマンド・追加環境変数も指定して起こす。
  init(cwd: String, command: String? = nil, env: [String: String] = [:]) {
    resumeSpawn = nil
    view = SurfaceScrollView(surfaceView: SurfaceView(frame: .zero, cwd: cwd))
    surface.initialCommand = command
    surface.initialEnv = env
    surface.tab = self
  }

  /// 永続から復元した agent セッションを resume 起動の (command, env) に解決する。
  /// 解決できなければ nil（呼び出し側は素のシェルで復元）。
  typealias ResumeSpawn = (AgentSession) -> (command: String, env: [String: String])?

  /// 休眠チケットの消費（materialize 開始）時に resume を解決する resolver。
  /// 復元時ではなく消費時に解決するため保持する（通常タブは nil）。
  private let resumeSpawn: ResumeSpawn?

  /// 永続スナップショット（TabState）から起こす。agent 付きなら休眠チケット（`.dormant`）のまま
  /// 起こし、resume 解決は消費時（`recordMaterializationStarted`）まで遅延する。
  init(restoring state: TabState, resumeSpawn: @escaping ResumeSpawn) {
    self.resumeSpawn = resumeSpawn
    view = SurfaceScrollView(surfaceView: SurfaceView(frame: .zero, cwd: state.cwd))
    explicitTitle = state.explicitTitle
    if let agent = state.agent { agentSlot = .dormant(agent) }
    surface.tab = self
  }

  /// materialize 開始を記録し、起動指示を確定する。休眠チケットは一度きり消費する——resume を
  /// (command, env) に解決して同一性を live へ引き継ぐ（解決できなければ素シェル化）。最後に Orbe
  /// runtime 契約の env（`ORBE_TAB` / `ORBE_SOCK` 等）を注入する。attach（surface 生成）前に
  /// 呼ばれるため起動指示は spawn に効き、最初の hook 報告も live で扱われる。
  /// 起床は同一性の寿命の節目でもある——resume が解けたら `opened`、解けなければ `unresolved` で終わる。
  func recordMaterializationStarted() {
    guard !activated else { return }
    activated = true
    if case .dormant(let session) = agentSlot {
      let identity = identity(of: agentSlot)
      if let spawn = resumeSpawn?(session) {
        surface.initialCommand = spawn.command
        surface.initialEnv = spawn.env
        agentSlot = .live(session: session, report: nil)
        if let identity { onIdentityTransition?(.opened(identity)) }
      } else {
        agentSlot = .none
        if let identity {
          onIdentityTransition?(.closed(identity, origin: .unresolved, reason: nil))
        }
      }
    }
    OrbeRuntimeEnv.inject(into: &surface.initialEnv, tabId: id)
  }

  /// エージェント hook の状態報告を slot へ適用する（`report_agent`）。戻り値は state の実変化
  /// （同値の連続報告・dormant での破棄・無からの clear は false）。遷移は現 slot × state で決まる:
  /// `.none` は clear が no-op・それ以外の報告で live 化（手動起動・spawn_agent の初回 hook という
  /// 正規経路）。`.live` は clear で `.none` へ・それ以外は同一性と報告を更新する。`.dormant`
  /// （未消費チケット）宛は**破棄**——チケットは報告で消費・変異できず、dormant タブは surface
  /// 未生成で報告主のプロセスが存在しえない（届く報告は必ず偽）。
  ///
  /// 同一性の更新は `AgentSession.updated` が持つ（command は常に上書き・sessionId は同じ CLI
  /// からの報告のあいだだけ sticky）。適用の前後で同一性を比べ、終わった同一性は `closed(agent)`
  /// （`reason` は hook が運ぶ終了理由）、得た同一性は `opened` として上位へ渡す——sessionId が
  /// A→B へ変わる報告では `closed(A)` → `opened(B)` の順。
  ///
  /// Attention 用の保持: stateChangedAt は **state の値が実際に変わったときだけ** `now` に更新する
  /// （working→working の連続報告で一覧の並びが暴れない）。message は state の遷移で確定し直し、
  /// 同じ state が続くあいだは **ツール由来（`source == "tool"`）の文言を、ツール由来でない報告
  /// （通知由来・文言なし）で上書きしない**。1 つの待ちを複数の hook が順に報告する CLI があるため（claude は
  /// AskUserQuestion のダイアログを開く時点で質問文を、その約 6 秒後に汎用の定型文を撃つ）、
  /// 出所で守らないと具体的な文言が定型文に潰れる。逆に通知由来どうしは上書きし合う——待ちの主体が
  /// このタブのエージェントとは限らず（teammate の worker が出す承認要求はリーダーのタブへ
  /// 即時に届き、要求ごとに文言が違う）、保持すると別の待ちの文言が居残るため。
  @discardableResult
  func applyReport(_ report: AgentHookReport, now: Date = Date()) -> Bool {
    let (agent, state, sessionId, message) = (
      report.agent, report.state, report.sessionId, report.message
    )
    let before = identity(of: agentSlot)
    var changed = false
    // 遷移表そのもの。網羅 switch なので、`AgentSlot` にケースが増えたら必ずここの判断を求められる。
    switch agentSlot {
    case .dormant:
      break  // 破棄——このタブの slot は一切変えない。
    case .live where state == "clear":
      agentSlot = .none
      changed = true
    case .none where state == "clear":
      break  // 既に無。
    case .none, .live:
      let session =
        agentSlot.session?.updated(command: agent, sessionId: sessionId)
        ?? AgentSession(command: agent, sessionId: sessionId)
      if let prior = agentReport, prior.state == state {
        // 同値の連続報告: 時刻は維持し、ツール由来の文言を弱い報告から守る。
        let keep = message?.source != "tool" && prior.message?.source == "tool"
        agentSlot = .live(
          session: session,
          report: AgentReport(
            state: state, message: keep ? prior.message : message,
            stateChangedAt: prior.stateChangedAt))
      } else {
        // 実変化（.none・report なしからの誕生を含む）。
        agentSlot = .live(
          session: session,
          report: AgentReport(state: state, message: message, stateChangedAt: now))
        changed = true
      }
    }
    let after = identity(of: agentSlot)
    if let before, before != after {
      onIdentityTransition?(.closed(before, origin: .agent, reason: report.reason))
    }
    if let after, before != after { onIdentityTransition?(.opened(after)) }
    return changed
  }

  /// タブが store から外れる（`SessionStore` の口が配列から外す前に告げる）。同一性が残っていれば
  /// その終わりとして `origin` を写す。slot は触らない——タブの消滅は `tab_closed` が既に語る。
  func recordDetached(origin: TabCloseOrigin) {
    guard let identity = identity(of: agentSlot) else { return }
    onIdentityTransition?(.closed(identity, origin: origin.sessionLogOrigin, reason: nil))
  }

  /// 述語を満たす state の live スロットだけ `idle` へ書き戻す。同一性（session）・文言・状態変化時刻は
  /// 運んだまま state だけ書き換えるため resume も Attention の並びも壊さない。
  /// `.dormant` / `.none` / 報告なしの `.live` は触らない。didSet が実変化を `agent_state` へ emit する。
  /// 同一性は変わらないので寿命の遷移は出ない。
  func settleReport(toIdleWhere shouldSettle: (String) -> Bool) {
    guard case .live(let session, .some(var report)) = agentSlot, shouldSettle(report.state)
    else { return }
    report.state = "idle"
    agentSlot = .live(session: session, report: report)
  }

  /// resume できる同一性（sessionId が確定している session）。無ければ nil。
  private func identity(of slot: AgentSlot) -> SessionEvent.Agent? {
    guard let session = slot.session, let sessionId = session.sessionId else { return nil }
    return SessionEvent.Agent(command: session.command, sessionId: sessionId)
  }

  /// surface からのウィンドウレベル chrome キー（タブ・workspace）を上位へ転送する。
  func requestWindowCommand(_ command: WindowCommand) {
    onWindowCommand?(command)
  }

  /// surface のタイトルが変わった（`SurfaceView.title` の didSet が実変化時だけ呼ぶ）。
  func titleChanged() {
    ControlServer.shared.emit(.title(tabId: id, title: surface.title))
    onTitleChange?()
  }

  /// surface が OSC 7 で cwd を報告した（`SurfaceView.currentPwd` の didSet が実変化時だけ呼ぶ）。
  func pwdChanged() {
    ControlServer.shared.emit(.pwd(tabId: id, path: surface.currentPwd))
    onPwdChange?()
  }

  /// このタブを閉じる要求（⌘W・シェル exit）。libghostty コールバック・keyDown の最中に surface を
  /// 解放しないよう main-queue 1 tick 後に上位（`WindowController.closeTab`）へ渡す。
  /// `origin` は判断せずそのまま素通しする。
  func close(origin: TabCloseOrigin) {
    DispatchQueue.main.async { [weak self] in self?.onClose?(origin) }
  }

  /// このタブの復元単位（cwd・エージェントセッション・明示タイトル）。起動時の一括保存
  /// （WorkspacePersistence）が読み、復元は `TerminalTab(restoring:)` が同じ形を受ける。
  /// 永続化するのは sessionId が確定している同一性だけ（resume 不能な記録を書かない）。
  func tabState() -> TabState {
    TabState(
      cwd: cwd, agent: agentSlot.session.flatMap { $0.sessionId != nil ? $0 : nil },
      explicitTitle: explicitTitle)
  }

  deinit {
    ControlServer.shared.emit(.tabClosed(tabId: id))
  }
}
