import AppKit
import GhosttyKit

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

  /// このタブを閉じる通知。閉鎖の発火源を添えて渡す（復元スタックへ積むかの判定に要る）。
  var onClose: ((TabCloseOrigin) -> Void)?
  /// タイトルが変わった通知（タブラベル更新用。再算出は呼び出し側が全タブで行う）。
  var onTitleChange: (() -> Void)?
  /// ウィンドウレベルの chrome 操作を上位へ届ける通知。
  var onWindowCommand: ((WindowCommand) -> Void)?
  /// OSC 7 で cwd が報告された通知（chrome の cwd 表示・永続保存用）。
  var onPwdChange: (() -> Void)?
  /// エージェントスロットが変わった通知（タブのインジケータ・横断ロールアップ更新用）。
  var onAgentStateChange: (() -> Void)?

  /// Cmd+R で付けた明示タイトル（sticky・tab単位）。非nil・非空なら最優先。空入力で nil へ戻す。
  var explicitTitle: String?

  /// このタブの agent スロット（none / dormant / live）。永続しない（休眠チケットの同一性
  /// だけが保存 schema へ写る）。`agent_state` 制御イベントの emit は didSet が一元で担う——
  /// どの遷移経路でも、導出 `agentState` の実変化だけがイベントを流す。chrome の再投影は
  /// スロットの実変化（文言・sessionId の更新を含む）で行う。順序は emit → 通知——通知先の
  /// done 消費が再入して idle を書くとき、履歴が done → idle の順に並ぶ。
  var agentSlot: AgentSlot = .none {
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

  /// 所属セグメントのキー＝cwd が属する git worktree ルート（管理外は cwd 自身）の正準形パス。
  /// cwd が変わった時に 1 回だけ再計算し（`pwdChanged`）、永続しない（復元時に保存 cwd から同じ規則で
  /// 再計算する）。同キーのタブが配列上で隣接する不変条件は `SessionStore` が保証する。
  /// setter が internal なのは、不変条件の検証がキーの純配列ロジックで済むよう注入口を残すため
  /// （書くのは init・`pwdChanged`・テストだけ）。
  var groupKey: String

  /// 「管理外は cwd 自身」というタブグループの規則。
  static func groupKey(cwd: String) -> String {
    GitWorktreeRoot.locate(cwd: cwd) ?? GitWorktreeRoot.normalizedPath(cwd)
  }

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
    groupKey = Self.groupKey(cwd: cwd)
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
    groupKey = Self.groupKey(cwd: state.cwd)
    explicitTitle = state.explicitTitle
    if let agent = state.agent { agentSlot = .dormant(agent) }
    surface.tab = self
  }

  /// materialize 開始を記録し、起動指示を確定する。休眠チケットは一度きり消費する——resume を
  /// (command, env) に解決して同一性を live へ引き継ぐ（解決できなければ素シェル化）。最後に Orbe
  /// runtime 契約の env（`ORBE_TAB` / `ORBE_SOCK` 等）を注入する。attach（surface 生成）前に
  /// 呼ばれるため起動指示は spawn に効き、最初の hook 報告も live で扱われる。
  func recordMaterializationStarted() {
    guard !activated else { return }
    activated = true
    if case .dormant(let session) = agentSlot {
      if let spawn = resumeSpawn?(session) {
        surface.initialCommand = spawn.command
        surface.initialEnv = spawn.env
        agentSlot = .live(session: session, report: nil)
      } else {
        agentSlot = .none
      }
    }
    OrbeRuntimeEnv.inject(into: &surface.initialEnv, tabId: id)
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
    groupKey = Self.groupKey(cwd: cwd)
    onPwdChange?()
  }

  /// このタブを閉じる要求（⌘W・シェル exit）。libghostty コールバック・keyDown の最中に surface を
  /// 解放しないよう main-queue 1 tick 後に上位（`WindowController.closeTab`）へ渡す。
  /// `origin` は判断せずそのまま素通しする。
  func close(origin: TabCloseOrigin) {
    DispatchQueue.main.async { [weak self] in self?.onClose?(origin) }
  }

  /// このタブの復元単位（cwd・エージェントセッション・明示タイトル）。
  /// 起動時の一括保存（WorkspacePersistence）と、閉じたタブの復元（⇧⌘T）が共有する——
  /// 両者の契約が同一であることを、同じコードを通ることで保証する。
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
