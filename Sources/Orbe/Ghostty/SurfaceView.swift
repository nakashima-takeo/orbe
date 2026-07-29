import AppKit
import GhosttyKit
import SwiftUI

/// occlusion（可視性）の導出と差分ゲート（純ロジック。SurfaceVisibilityTests が検証）。
/// libghostty の可視性契約: 不可視で `set_occlusion(false)`（描画停止・端末状態は前進）、
/// 可視復帰で `set_occlusion(true)`（display link 再開前に 1 フレーム同期描画が保証される）。
struct SurfaceOcclusionGate {
  /// 前回 libghostty へ送った可視値。未送信は nil で初回は必ず送る——renderer の visible
  /// 初期値は true のため、隠れ状態で生まれる surface（遅延 mount）には false を届ける必要がある。
  private(set) var lastSent: Bool?

  /// 「タブ可視 AND ウィンドウ可視」の合成。window 未接続（デタッチ中）・自分/祖先の
  /// isHidden（タブ切替）・ウィンドウ occluded（最小化・別 Space）のいずれかで不可視。
  static func derive(inWindow: Bool, hiddenOrHasHiddenAncestor: Bool, windowVisible: Bool) -> Bool {
    inWindow && !hiddenOrHasHiddenAncestor && windowVisible
  }

  /// desired を送るべきか判定し、送るなら記録する（同値スキップの差分ゲート・冪等）。
  mutating func shouldSend(_ desired: Bool) -> Bool {
    guard desired != lastSent else { return false }
    lastSent = desired
    return true
  }
}

/// libghostty surface を 1 つ埋め込む NSView。
/// 描画は libghostty が Metal で行い、本 View は入力・サイズ・フォーカスを surface へ橋渡しする。
final class SurfaceView: NSView {
  private var surface: ghostty_surface_t?
  /// occlusion 差分ゲート（前回送信値）。読み書きは main のみ（syncOcclusion 経由）。
  private var occlusionGate = SurfaceOcclusionGate()
  /// 所属 window の occlusion 通知購読。viewDidMoveToWindow で付け替える。
  private var occlusionObserver: NSObjectProtocol?
  /// 制御チャネルの宛先 ID（外部からこのペインを一意に指す）。
  let id = IdGen.next()
  /// 所属するレイアウト。分割/クローズの委譲先。
  weak var controller: TerminalController?
  /// 分割で生成された場合の継承元ペイン（フォント・cwd 等を継承する）。
  /// weak かつ view 参照——生 surface ポインタだと、surface 生成を遅延する経路
  /// （背景 workspace への制御 split 等）で継承元が先に解放されると UAF になる。
  /// weak view なら解放時に nil へ落ち、既定 config で安全に起きる。
  weak var inheritFrom: SurfaceView?
  /// シェルが報告するタイトル（OSC 0/2）。タブ表示に使う。
  var paneTitle: String = "" {
    didSet {
      if paneTitle != oldValue {
        ControlServer.shared.emit(ControlEvent(kind: "pane_title", paneId: id, value: paneTitle))
      }
    }
  }
  /// シェルが OSC 7 で報告した現在の cwd（永続の保存値）。
  var currentPwd: String? {
    didSet {
      if currentPwd != oldValue {
        ControlServer.shared.emit(ControlEvent(kind: "pwd", paneId: id, value: currentPwd))
      }
    }
  }
  /// エージェント hook が制御ソケット（report_agent）で報告した現在の状態
  /// （idle/working/waiting/done）。走っていない / clear 時は nil。タブのインジケータ集約が読む。
  var agentState: String? {
    didSet {
      if agentState != oldValue {
        ControlServer.shared.emit(ControlEvent(kind: "agent_state", paneId: id, value: agentState))
      }
    }
  }
  /// エージェント hook が報告した resume 用セッション ID（後続ユニットが永続して再開に使う）。
  var agentSessionId: String?
  /// エージェント hook が報告した CLI 名（claude/codex/agy）。resume コマンドの構築に使う。
  var agentCommand: String?
  /// エージェント hook が報告した文言（waiting の質問文・done の最終応答）。Attention 一覧が読む。
  /// clear 以外の報告でも毎回上書きする（省略時は nil＝stale な文言を残さない）。永続しない。
  var agentMessage: String?
  /// agentState の値が実際に変わった時刻（Attention 一覧の並び・経過時間表示）。
  /// 同値の連続報告・done のフォーカス消費（done→idle）では動かさない。永続しない。
  var agentStateChangedAt: Date?
  /// 復元時の起動 cwd（surface を working_directory 付きで起こす。inheritFrom が無いとき有効）。
  var initialCwd: String?
  /// 起動時にシェルの代わりに走らせるコマンド（エージェント起動タブ・split の command 指定）。
  /// 継承の有無に依らず適用する（cwd は inherited_config が運び、その上でこのコマンドを起こす）。
  var initialCommand: String?
  /// 起動時に追加する環境変数（エージェント起動タブ。inheritFrom が無いとき有効）。
  var initialEnv: [String: String] = [:]

  /// 内部の surface ハンドル（cwd 継承元として参照される）。
  var surfacePtr: ghostty_surface_t? { surface }

  // MARK: - スクロールバー状態（更新ロジックは SurfaceView+Scrollbar.swift。ラップ層が読む）

  /// libghostty が報告する scrollback の状態。未報告なら nil。更新は updateScrollbar 経由のみ。
  var scrollbar: ScrollbarState?
  /// セルのポイント寸法。行↔ピクセル換算に使う。更新は updateCellSize 経由のみ。
  var cellSize: CGSize = .zero
  /// scrollbar / cellSize が更新されたとき呼ばれる（SurfaceScrollView が同期する）。
  var onScrollbarUpdate: (() -> Void)?

  // MARK: - スクロール pending（蓄積 + 合体 flush。挙動は SurfaceView+Mouse.swift）

  /// `scrollWheel` で受理した delta を次 tick の flush まで貯める累積（precision 時 2x 適用後）。
  /// main(AppKit) スレッド上でのみ読み書きする。
  var pendingScrollX: Double = 0
  var pendingScrollY: Double = 0
  /// flush で libghostty へ渡す scroll mods（最新の `scrollMods(...)` 値で上書き）。
  var pendingScrollMods = ghostty_input_scroll_mods_t()
  /// flush の多重スケジュール防止フラグ。同一 tick の N 回受理を 1 回の flush に畳む。
  var scrollFlushScheduled = false

  /// 任意位置へスクロールさせる（NSScrollView ラップ層のドラッグから呼ぶ）。
  func scrollToRow(_ row: Int) {
    surfaceBinding("scroll_to_row:\(row)")
  }

  /// surface の userdata（不透明ポインタ）から SurfaceView を復元する。
  /// クリップボード等のコールバックが対象ペインを特定するのに使う。
  static func from(_ userdata: UnsafeMutableRawPointer) -> SurfaceView {
    Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    // wantsLayer は立てない。libghostty の Metal レンダラが自前の IOSurfaceLayer を
    // 代入してから wantsLayer=true を立てることで view を layer-hosting にする
    // （順序が逆だと layer-backed になり、IOSurfaceLayer の暗黙アニメ無効化が効かず
    // スクロールがカクつく）。cf. vendor/ghostty src/renderer/Metal.zig。
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var acceptsFirstResponder: Bool { true }

  // MARK: - ライフサイクル

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    rewireOcclusionObserver()
    guard let win = window else {
      syncOcclusion()  // デタッチ（WS 切替）。不可視を送って描画を止める。
      return
    }
    guard surface == nil else {
      // 再アタッチ（タブ切替等）。detach 中のリサイズで狂った scale/size を実 window 値で再同期。
      updateSize()
      syncOcclusion()
      return
    }
    createSurface(in: win)
  }

  /// window の occlusion 通知購読を付け替える（旧 window の購読を解除・新 window を購読）。
  private func rewireOcclusionObserver() {
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    occlusionObserver = window.map { win in
      NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main
      ) { [weak self] _ in self?.syncOcclusion() }
    }
  }

  /// surface を生成する（初回の window 参加時に一度だけ）。
  private func createSurface(in win: NSWindow) {
    // 分割で生まれたペインはフォント・cwd 等を親から継承（cwd は OSC 7 経由で
    // ghostty が記憶した値を inherited_config が運ぶ）、ルートは既定 config。
    var sc =
      inheritFrom?.surfacePtr.map {
        ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_SPLIT)
      }
      ?? ghostty_surface_config_new()
    sc.platform_tag = GHOSTTY_PLATFORM_MACOS
    sc.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
    sc.userdata = Unmanaged.passUnretained(self).toOpaque()  // コールバックから自分を復元
    sc.scale_factor = win.backingScaleFactor
    // font_size 0 = config の font-size を使う（キュレート既定）。分割は親を継承。

    // 復元・エージェント起動時は cwd / 起動コマンド / 環境変数を指定して起こす（ルートのみ。
    // 分割は親から継承）。ポインタは ghostty_surface_new 呼び出し中だけ有効——
    // strdup で固定し呼び出し後に解放する。
    var owned: [UnsafeMutablePointer<CChar>] = []
    defer { owned.forEach { free($0) } }
    func retain(_ s: String) -> UnsafePointer<CChar> {
      let p = strdup(s)!
      owned.append(p)
      return UnsafePointer(p)
    }
    var env: [String: String] = [:]
    if inheritFrom == nil {
      if let cwd = initialCwd { sc.working_directory = retain(cwd) }
      env = initialEnv
    }
    // command は継承の有無に依らず適用する（split の command 指定でも指定コマンドで起こす。
    // 継承 cwd は inherited_config が運び、その上でこのコマンドが動く）。
    if let command = initialCommand { sc.command = retain(command) }
    // 同梱 CLI（bare `orb`）を全ペイン（root＋split）の PATH 先頭へ前置する。split は libghostty の
    // inherited_config が bin/ 入り PATH を運ばないため、ここで明示しないと split 内で `orb` が
    // not found になる。衝突は改名で解消済みゆえ、bin/ が PATH に在れば順序非依存で解決する。
    Self.prependBundledBin(to: &env)
    // pane identity を全ペインへ注入する。split は親プロセスの env を継承するので、
    // 自分の id で ORBE_PANE を上書きしないと親ペイン id で誤報告する。エージェント hook
    // （シム → orbe-report）はこれらが無ければ no-op。ORBE_REPORT_BIN は同梱 binary の
    // 絶対パス（swift run では未解決→未設定＝no-op）。ORBE_SOCK はこのインスタンスの socket。
    env["ORBE_PANE"] = String(id)
    if let bin = Self.reportBinaryPath { env["ORBE_REPORT_BIN"] = bin }
    let sock = ControlServer.shared.socketPath
    if !sock.isEmpty { env["ORBE_SOCK"] = sock }
    var envs = env.map { ghostty_env_var_s(key: retain($0.key), value: retain($0.value)) }
    let surf: ghostty_surface_t? = envs.withUnsafeMutableBufferPointer { buf in
      if let base = buf.baseAddress, buf.count > 0 {
        sc.env_vars = base
        sc.env_var_count = buf.count
      }
      return ghostty_surface_new(Ghostty.shared.app, &sc)
    }
    guard let surf else { return }
    surface = surf
    syncColorScheme()  // light:/dark: テーマ解決に現在の外観を通知（初期 LIGHT のままだと白くなる）
    ghostty_surface_set_focus(surf, false)  // 初期は非フォーカス（becomeFirstResponder で点灯）
    Ghostty.shared.register(surf, view: self)
    updateSize()
    // 生成時同期。renderer の visible 初期値は true のため、隠れ mount（viewDidHide は
    // 「既に隠れている祖先への追加」では発火しない）には初回送信で false を確実に届ける。
    syncOcclusion()
    Ghostty.shared.tick()
  }

  // MARK: - 可視性（occlusion）同期

  /// 可視性の合成値を libghostty へ差分同期する choke-point。タブ切替（isHidden トグル）・
  /// WS 切替（デタッチ/再アタッチ）・ウィンドウ occlusion 変化・surface 生成の全経路が
  /// AppKit コールバック経由でここへ集約される。可視へ転じたときは `updateSize()` を
  /// 無条件再アサートし、setFrameSize が届かない可視化経路でもサイズ再収束を保証する
  /// （ゼロサイズ surface は stale contents すら描かず完全透明になるため）。
  private func syncOcclusion() {
    dispatchPrecondition(condition: .onQueue(.main))  // 前回送信値の一貫性のため main 固定
    guard let surface else { return }  // 未生成。初回送信は生成時の syncOcclusion が担う
    let desired = SurfaceOcclusionGate.derive(
      inWindow: window != nil,
      hiddenOrHasHiddenAncestor: isHiddenOrHasHiddenAncestor,
      windowVisible: window?.occlusionState.contains(.visible) ?? false)
    guard occlusionGate.shouldSend(desired) else { return }
    ghostty_surface_set_occlusion(surface, desired)
    if desired { updateSize() }
  }

  /// 自分または祖先（rootContainer）の isHidden 変化。タブ切替の不可視化経路。
  override func viewDidHide() {
    super.viewDidHide()
    syncOcclusion()
  }

  /// 自分または祖先の isHidden 解除。タブ切替の可視化経路（setFrameSize が来ないことがある）。
  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncOcclusion()
  }

  /// `theme = light:...,dark:...` を解決させるため、現在の effectiveAppearance を surface へ通知する。
  /// ホストが通知しないと libghostty は LIGHT 既定のままになる。
  private func syncColorScheme() {
    guard let surface else { return }
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ghostty_surface_set_color_scheme(
      surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncColorScheme()  // システムのライト/ダーク切替に追従
  }

  deinit {
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    ControlServer.shared.emit(ControlEvent(kind: "pane_closed", paneId: id, value: nil))
    if let surface {
      Ghostty.shared.unregister(surface)
      ghostty_surface_free(surface)
    }
  }

  // MARK: - サイズ / スケール

  /// AppKit bounds（ポイント）と scale から libghostty へ渡すピクセルサイズを導出する。
  /// レイアウト途中の不正・ゼロ面積フレーム（負・NaN・∞・ゼロ）は nil（＝サーフェスへ渡さない）。
  /// libghostty は非負・非ゼロ面積・確定 scale を事前条件とする。
  static func surfacePixels(bounds: CGSize, scale: CGFloat) -> (width: UInt32, height: UInt32)? {
    guard scale > 0, bounds.width > 0, bounds.height > 0 else { return nil }
    let w = (bounds.width * scale).rounded(.down)
    let h = (bounds.height * scale).rounded(.down)
    guard w.isFinite, h.isFinite, w >= 1, h >= 1 else { return nil }
    return (UInt32(w), UInt32(h))
  }

  /// point↔pixel 変換のスケール。window 未接続時は Retina(2x) を仮定する。
  /// updateSize（point→pixel）と updateCellSize（pixel→point）が対で参照する単一の既定値。
  var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

  private func updateSize() {
    dispatchPrecondition(condition: .onQueue(.main))  // surface 操作は main 固定（外部契約）
    guard let surface else { return }
    let scale = backingScale
    // 中間の不正／ゼロ面積フレームは C API へ渡さない。settle 後の有効フレームで後着更新される。
    guard let px = Self.surfacePixels(bounds: bounds.size, scale: scale) else { return }
    ghostty_surface_set_content_scale(surface, scale, scale)
    ghostty_surface_set_size(surface, px.width, px.height)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateSize()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    // 本家パリティ: libghostty が代入した IOSurfaceLayer の contentsScale を実 window 値へ
    // 同期する（暗黙アニメを切って即時反映）。cf. ghostty SurfaceView_AppKit.swift。
    if let window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }
    updateSize()  // Retina ⇔ 1x のディスプレイ間移動に scale を追従させる
  }

  // MARK: - フォーカス

  func setSurfaceFocus(_ focused: Bool) {
    if let surface { ghostty_surface_set_focus(surface, focused) }
  }

  override func becomeFirstResponder() -> Bool {
    setSurfaceFocus(true)
    controller?.focusedPaneChanged(self)
    return super.becomeFirstResponder()
  }
  override func resignFirstResponder() -> Bool {
    setSurfaceFocus(false)
    return super.resignFirstResponder()
  }

  // MARK: - 修飾キー変換

  func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var m: UInt32 = 0
    if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: m)
  }

  // MARK: - surface バインディング

  /// surface へ binding action 文字列を送る汎用ディスパッチャ（chrome/search/scroll から使う）。
  func surfaceBinding(_ cmd: String) {
    guard let surface else { return }
    cmd.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(cmd.utf8.count)) }
  }

  /// 所属ウィンドウの背景透過ホルダー（`WindowController` 所有）。浮遊 popup（検索バー・補完）を
  /// 均一ガラスへ乗せる単一注入点。窓の delegate（= WindowController）から解決し、窓に未参加や
  /// 解決不能なら nil（呼び出し側は不透明既定へフォールバック）。
  var chromeTranslucency: ChromeTranslucency? {
    (window?.delegate as? WindowController)?.chromeTranslucency
  }

  /// 所属ウィンドウの現在言語ホルダー（`WindowController` 所有）。浮遊 popup（検索バー）を選択言語で描き、
  /// 設定切替へ一斉追従させる単一注入点。窓の delegate（= WindowController）から解決し、解決不能なら nil。
  var localization: LocalizationStore? {
    (window?.delegate as? WindowController)?.localization
  }

  // MARK: - スクロールバック検索の状態（メソッド実体は SurfaceView+Search.swift）

  var searchBar: SearchBar?
  var searchSelected: Int?
  var searchTotal: Int?

  // MARK: - 補完ドロップダウン（メソッド実体は SurfaceView+Completion.swift）

  /// 補完 popup（非 nil=表示中）と非同期取得の状態（requestSeq=stale ガード・appliedSeq=反映済み token〔不一致中は accept 退避〕・debounce=取得ワーク）。
  var completion: CompletionController?
  var completionCard: NSHostingView<CompletionSideCard>?
  var completionRequestSeq = 0
  var completionAppliedSeq = 0
  var completionDebounce: DispatchWorkItem?

  /// Enter 確定（advance=false）直後の buffer/cursor スナップショット。以後の completion_update が
  /// これと完全一致（＝確定以降なにも変化していない）の間は popup を再表示しない（再表示ループを断つ）。
  /// buffer/cursor が動くか completionEnd で掃除され nil に戻る。
  var completionSuppressed: (buffer: String, cursor: Int)?

  // MARK: - IME（preedit / 確定）の状態。プロトコル実装は SurfaceView+IME.swift

  /// IME 変換中の未確定文字列（preedit）。空なら非 composition 中。
  var markedText = NSMutableAttributedString()
  /// keyDown 中だけ非 nil。interpretKeyEvents が呼ぶ insertText の確定文字を貯める。
  var keyTextAccumulator: [String]?
}
