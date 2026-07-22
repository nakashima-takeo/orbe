import AppKit
import GhosttyKit

/// 分割比を保持する NSSplitView。復元時に保存比率を一度だけ divider に適用する。
/// 現在比 `ratio` は実フレームから算出するため、ユーザーのドラッグ結果も保存値に反映される
/// （未レイアウトの非アクティブ workspace では復元値をそのまま返す）。
final class WorkspaceSplitView: NSSplitView {
  private var restored: Double = 0.5
  private var pending = false

  func restore(ratio: Double) {
    restored = ratio
    pending = true
    needsLayout = true
  }

  var ratio: Double {
    guard arrangedSubviews.count == 2 else { return restored }
    let total = isVertical ? bounds.width : bounds.height
    guard total > 0 else { return restored }
    let first = arrangedSubviews[0].frame
    return Double((isVertical ? first.width : first.height) / total)
  }

  override func layout() {
    super.layout()
    guard pending, arrangedSubviews.count == 2 else { return }
    let total = isVertical ? bounds.width : bounds.height
    guard total > 0 else { return }
    // setPosition は同期的に layout() を再入させる。先に pending を倒さないと
    // 復元比が 0.5 以外（= 実際に divider が動く）のとき無限再帰でスタックを溢れさせる。
    pending = false
    setPosition(total * CGFloat(restored), ofDividerAt: 0)
  }
}

/// 1 ウィンドウ内のペイン分割ツリーを所有する（host 所有のレイアウト）。
/// libghostty はジオメトリを管理しないため、NSSplitView ツリーは Orbe が構築する。
///
/// この分割ツリーは意図的に AppKit NSSplitView のまま据え置く（SwiftUI 化しない）。
/// SwiftUI が分割ツリーを所有すると、分割/クローズのたびに葉の `SurfaceScrollView` が
/// 作り直され、scrollback と非アクティブ workspace の keep-alive（NSView 同一性に依存）を
/// 壊す（cf. ghostty-org/ghostty#9444）。純正 HSplitView/VSplitView は再帰ネスト・比率保存・
/// プログラム的 divider 制御を持たない。SwiftUI ルート下では `AppShell` が content
/// representable でこのツリーを内包する（端末まわりは AppKit が正しい責務）。
final class TerminalController {
  /// ペインから届く、ウィンドウレベルの chrome 操作（タブ・workspace）。
  enum WindowCommand {
    case newTab
    case nextTab
    case prevTab
    case prevTool
    case nextTool
    case switchWorkspace
    case newWorkspace
    case toggleEditorPane
    case launchDefaultAgent
    case showAgentPalette
    case showDispatchPalette
    case openEditor
    case renameTab
    case showSettings
  }

  /// 制御チャネルの宛先 ID（外部からこのタブを一意に指す）。
  let id = IdGen.next()
  let rootContainer = NSView()
  private(set) weak var focusedPane: SurfaceView?

  /// 最後のペインが閉じられた（このタブを閉じるべき）通知。
  var onEmpty: (() -> Void)?
  /// アクティブペインのタイトルが変わった通知（タブラベル更新用。再算出は呼び出し側が全タブで行う）。
  var onActiveTitleChange: (() -> Void)?
  /// 分割/クローズでレイアウトが変わった通知（永続の保存スケジュール用）。
  var onLayoutChange: (() -> Void)?
  /// ウィンドウレベルの chrome 操作を上位へ届ける通知。
  var onWindowCommand: ((WindowCommand) -> Void)?
  /// ペインが OSC 7 で cwd を報告した通知（chrome の cwd 表示・永続保存用）。
  var onPwdChange: (() -> Void)?
  /// いずれかのペインのエージェント状態が変わった通知（タブのインジケータ更新用）。
  /// title 経路と違い focus 限定せず、裏 split の変化でもタブを更新する。
  var onAgentStateChange: (() -> Void)?

  /// Cmd+R で付けた明示タイトル（sticky・tab単位）。非nil・非空なら最優先。空入力で nil へ戻す。
  var explicitTitle: String?

  /// このタブの EditorPane UI 状態（単一真実）。開閉・ツール・選択・下書き等をタブ単位で保持し、
  /// タブ切替で復元する。永続は open/tool の粗粒度のみ（WorkspacePersistence）。
  let editorUI = EditorPaneUIState()

  /// 復元時に元 PaneNode が持っていた agent != nil leaf 数（休眠 agent の総数）。
  /// resume 未対応で素シェル化した leaf も、変換前の node から数えるため取りこぼさない。
  /// 通常（新規）タブは 0。休眠 workspace は活性化前にミューテートされないため不変で正しい。
  let restoredAgentCount: Int

  /// このタブの表示タイトル。① explicitTitle ?? ② アプリ報告タイトル ?? ③ derived(cwd, root)。
  /// rootPath は所属 Workspace が持つため呼び出し側（WindowController）から渡す。
  /// ② は paneTitle が非空かつ currentPwd と異なるときだけ採用する。libghostty は明示タイトル
  /// （OSC 2）未受信の間、OSC 7 の生 pwd をタイトルに使う（stream_handler.zig reportPwd）ため、
  /// paneTitle == currentPwd は pwd フォールバック＝③の仕事の重複。生 pwd は出さず③で整形する。
  func displayTitle(workspaceRoot: String?) -> String {
    if let e = explicitTitle, !e.isEmpty { return e }
    return derivedTitle(workspaceRoot: workspaceRoot)
  }

  /// explicitTitle を無視した派生タイトル（②③）。インライン改名の field を空にしたときの
  /// 戻り先プレビュー（プレースホルダ）に使う。
  func derivedTitle(workspaceRoot: String?) -> String {
    if let pt = focusedPane?.paneTitle, !pt.isEmpty, pt != focusedPane?.currentPwd { return pt }
    if let pwd = focusedPane?.currentPwd ?? focusedPane?.initialCwd {
      return TabTitle.derive(pwd: pwd, root: workspaceRoot)
    }
    return ""
  }

  /// フォーカスを戻すべきペイン（最後にフォーカスしていたペイン、無ければ最初のペイン）。
  /// タブ切替・workspace 切替・パレットを閉じた時の復元はすべてこの規則に従う。
  var preferredFocusPane: SurfaceView? { focusedPane ?? firstPane(in: rootContainer) }

  /// 通常タブは引数なし。エージェント起動タブは cwd・起動コマンド・追加環境変数を指定して起こす。
  init(
    initialCwd: String? = nil, initialCommand: String? = nil, initialEnv: [String: String] = [:]
  ) {
    restoredAgentCount = 0
    let first = makePane(
      inheritFrom: nil, initialCwd: initialCwd, initialCommand: initialCommand,
      initialEnv: initialEnv)
    let leaf = wrap(first)
    leaf.frame = rootContainer.bounds
    leaf.autoresizingMask = [.width, .height]
    rootContainer.addSubview(leaf)
    focusedPane = first
  }

  /// 永続から復元した agent セッションを resume 起動の (command, env) に解決する。
  /// 解決できなければ nil（呼び出し側は素のシェルで復元）。
  typealias ResumeSpawn = (AgentSession) -> (command: String, env: [String: String])?

  /// 永続スナップショット（PaneNode）から分割ツリーを再構築する。
  /// agent 付きの葉は resumeSpawn で resume コマンドに解決し、起こす。
  init(restoring node: PaneNode, resumeSpawn: ResumeSpawn) {
    restoredAgentCount = node.agentLeafCount
    let root = buildView(from: node, resumeSpawn: resumeSpawn)
    root.frame = rootContainer.bounds
    root.autoresizingMask = [.width, .height]
    rootContainer.addSubview(root)
    focusedPane = firstPane(in: rootContainer)
  }

  private func buildView(from node: PaneNode, resumeSpawn: ResumeSpawn) -> NSView {
    switch node {
    case .leaf(let cwd, let agent):
      if let agent, let spawn = resumeSpawn(agent) {
        let pane = makePane(
          inheritFrom: nil, initialCwd: cwd, initialCommand: spawn.command, initialEnv: spawn.env)
        // resume 直後・最初の hook が来る前に snapshot しても agent 情報が保たれるよう再設定する。
        pane.agentCommand = agent.command
        pane.agentSessionId = agent.sessionId
        return wrap(pane)
      }
      return wrap(makePane(inheritFrom: nil, initialCwd: cwd))
    case .split(let vertical, let ratio, let first, let second):
      let split = WorkspaceSplitView()
      split.isVertical = vertical
      split.dividerStyle = .thin
      split.addArrangedSubview(buildView(from: first, resumeSpawn: resumeSpawn))
      split.addArrangedSubview(buildView(from: second, resumeSpawn: resumeSpawn))
      split.restore(ratio: ratio)
      return split
    }
  }

  func makePane(
    inheritFrom: SurfaceView?, initialCwd: String? = nil, initialCommand: String? = nil,
    initialEnv: [String: String] = [:]
  ) -> SurfaceView {
    let p = SurfaceView(frame: rootContainer.bounds)
    p.controller = self
    p.inheritFrom = inheritFrom
    p.initialCwd = initialCwd
    p.initialCommand = initialCommand
    p.initialEnv = initialEnv
    return p
  }

  /// SurfaceView をネイティブ overlay スクロールバー付きの NSScrollView でラップする。
  /// 分割ツリー上の「葉」はこのラップで、走査・分割・クローズはラップを単位に扱う。
  private func wrap(_ pane: SurfaceView) -> SurfaceScrollView {
    SurfaceScrollView(surfaceView: pane)
  }

  /// SurfaceView を内包する葉ラップ（SurfaceScrollView）を superview 鎖から辿る。
  private func leaf(of pane: SurfaceView) -> SurfaceScrollView? {
    var v: NSView? = pane.superview
    while let cur = v {
      if let leaf = cur as? SurfaceScrollView { return leaf }
      v = cur.superview
    }
    return nil
  }

  /// フォーカスを排他管理（旧ペインを必ず消灯）。
  func focusedPaneChanged(_ p: SurfaceView) {
    if let prev = focusedPane, prev !== p { prev.setSurfaceFocus(false) }
    focusedPane = p
    onActiveTitleChange?()
  }

  /// ペインのタイトル変更。フォーカス中ならタブラベルへ反映。
  func paneTitleChanged(_ p: SurfaceView) {
    if p === focusedPane { onActiveTitleChange?() }
  }

  /// ペインのエージェント状態変更。どのペインの変化でもタブのインジケータを更新する。
  func paneAgentStateChanged() {
    onAgentStateChange?()
  }

  /// タブ内の全ペインを優先順位 `waiting > working > done` で1つに畳んだ状態種別。
  /// idle・nil のみならグリフ無し（nil）。
  func aggregateAgentState() -> AgentStateIcon.Kind? {
    let priority = AgentRollup.priorityOrder
    var winner: SurfaceView?
    var winnerRank = priority.count
    forEachPane(in: rootContainer) { pane in
      guard let state = pane.agentState, let rank = priority.firstIndex(of: state) else { return }
      if rank < winnerRank {
        winnerRank = rank
        winner = pane
      }
    }
    guard let winner else { return nil }
    return AgentStateIcon.kind(state: winner.agentState)
  }

  /// このタブのペインのエージェント状態を状態種別ごとに件数集計する（`[state: count]`）。
  /// 件数の単位はペイン＝`agentState` を持つ `SurfaceView` 1 つを 1 件。
  /// 数えるのはロールアップが表示する状態のみ（`AgentRollup.countedStates`）＝集計と表示が一致する。
  func agentStateCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    forEachPane(in: rootContainer) { pane in
      guard let state = pane.agentState, AgentRollup.countedStates.contains(state) else { return }
      counts[state, default: 0] += 1
    }
    return counts
  }

  /// タブ活性化＝完了通知の消費。タブ内全ペインの `done` を `idle`（休止）に遷移させ、
  /// 集約 `done` バッジを消す（idle はタブに出ない）。エージェントは生きて入力待ち＝休止なので、
  /// nil（不在）ではなく idle にして横断集計に休止中として残す。`waiting`・`working` は残す。
  /// `agentCommand`・`agentSessionId` は触らないため resume を壊さない。
  func consumeDoneState() {
    forEachPane(in: rootContainer) { pane in
      if pane.agentState == "done" { pane.agentState = "idle" }
    }
  }

  private func forEachPane(in view: NSView, _ body: (SurfaceView) -> Void) {
    if let s = view as? SurfaceView {
      body(s)
      return
    }
    for sub in view.subviews { forEachPane(in: sub, body) }
  }

  /// このタブの全ペインをツリー順で返す（制御チャネルの列挙用）。
  func controlAllPanes() -> [SurfaceView] {
    var out: [SurfaceView] = []
    forEachPane(in: rootContainer) { out.append($0) }
    return out
  }

  /// ペインからのウィンドウレベル chrome キー（タブ・workspace）を上位へ転送する。
  func requestWindowCommand(_ command: WindowCommand) {
    onWindowCommand?(command)
  }

  /// ペインの OSC 7 cwd 報告を上位へ転送する。
  func panePwdChanged() {
    onPwdChange?()
  }

  /// ペインを分割する。`.horizontal` = 左右（縦線）、`.vertical` = 上下（横線）。
  /// `from` 省略時はフォーカス中ペイン（GUI 呼び出し）、指定時はそのペインを分割対象にする（制御 API）。
  /// `command` 指定時は新ペインをそのコマンドで起こす（省略時は素シェル。cwd は inherited_config で継承）。
  /// 戻りは新ペイン（GUI は @discardableResult で無視、制御 API は id を読む）。
  @discardableResult
  func split(
    _ orientation: NSUserInterfaceLayoutOrientation, from pane: SurfaceView? = nil,
    command: String? = nil
  ) -> SurfaceView? {
    guard let focused = pane ?? focusedPane ?? firstPane(in: rootContainer),
      let target = leaf(of: focused),
      let parent = target.superview
    else { return nil }
    // cwd は inherited_config が継承。command 指定時は新ペインをそのコマンドで起こす。
    let newPane = wrap(makePane(inheritFrom: focused, initialCommand: command))

    let split = WorkspaceSplitView()
    split.isVertical = (orientation == .horizontal)
    split.dividerStyle = .thin

    if let parentSplit = parent as? NSSplitView,
      let idx = parentSplit.arrangedSubviews.firstIndex(of: target)
    {
      split.frame = target.frame
      target.removeFromSuperview()
      split.addArrangedSubview(target)
      split.addArrangedSubview(newPane)
      parentSplit.insertArrangedSubview(split, at: idx)
    } else {
      split.frame = parent.bounds
      split.autoresizingMask = [.width, .height]
      target.removeFromSuperview()
      split.addArrangedSubview(target)
      split.addArrangedSubview(newPane)
      parent.addSubview(split)
    }

    split.restore(ratio: 0.5)  // 初期は均等
    let newSurface = newPane.surfaceView
    DispatchQueue.main.async { newSurface.window?.makeFirstResponder(newSurface) }
    onLayoutChange?()
    return newSurface
  }

  /// ペインを閉じる。残り 1 つになった分割は畳んで親へ昇格。最後の 1 枚ならタブを閉じる。
  /// フォーカス復元は preferredFocusPane の規則に従う（フォーカス外ペインの close —
  /// shell の exit 等 — で入力中のペインから奪わない）。
  func close(_ pane: SurfaceView) {
    guard let leaf = leaf(of: pane), let parent = leaf.superview else { return }
    guard let parentSplit = parent as? NSSplitView else {
      // ルート唯一のペイン → このタブを閉じる（保存は WindowController 側の closeTab で）。
      DispatchQueue.main.async { [weak self] in self?.onEmpty?() }
      return
    }

    if pane === focusedPane { focusedPane = nil }
    leaf.removeFromSuperview()
    // split は常にちょうど 2 子で構築・維持される → 1 枚外せば残りは必ず 1 つで、分割を畳む。
    guard let remaining = parentSplit.arrangedSubviews.first else { return }

    let grand = parentSplit.superview
    remaining.removeFromSuperview()
    if let grandSplit = grand as? NSSplitView,
      let idx = grandSplit.arrangedSubviews.firstIndex(of: parentSplit)
    {
      parentSplit.removeFromSuperview()
      grandSplit.insertArrangedSubview(remaining, at: idx)
    } else if let grand {
      let frame = parentSplit.frame
      parentSplit.removeFromSuperview()
      remaining.frame = frame
      remaining.autoresizingMask = [.width, .height]
      grand.addSubview(remaining)
    }
    // 畳み込みの付け替えで first responder が外れるため、生存ペインへ再付与する。
    DispatchQueue.main.async { [weak self] in
      guard let self, let target = self.preferredFocusPane else { return }
      target.window?.makeFirstResponder(target)
    }
    onLayoutChange?()
  }

  func firstPane(in view: NSView) -> SurfaceView? {
    if let s = view as? SurfaceView { return s }
    for sub in view.subviews {
      if let found = firstPane(in: sub) { return found }
    }
    return nil
  }

  /// 現在の分割ツリーを永続スナップショット（PaneNode）に落とす。
  func snapshot() -> PaneNode {
    guard let root = rootContainer.subviews.first else { return .leaf(cwd: nil, agent: nil) }
    return snapshotView(root)
  }

  private func snapshotView(_ v: NSView) -> PaneNode {
    if let leaf = v as? SurfaceScrollView { return snapshotView(leaf.surfaceView) }
    if let s = v as? SurfaceView {
      var agent: AgentSession?
      if let command = s.agentCommand, let sessionId = s.agentSessionId {
        agent = AgentSession(command: command, sessionId: sessionId)
      }
      return .leaf(cwd: s.currentPwd ?? s.initialCwd, agent: agent)
    }
    if let split = v as? WorkspaceSplitView, split.arrangedSubviews.count == 2 {
      return .split(
        vertical: split.isVertical, ratio: split.ratio,
        first: snapshotView(split.arrangedSubviews[0]),
        second: snapshotView(split.arrangedSubviews[1]))
    }
    return .leaf(cwd: nil, agent: nil)
  }
}
