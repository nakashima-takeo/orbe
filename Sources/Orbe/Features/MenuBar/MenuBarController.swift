import AppKit
import Observation
import SwiftUI

/// メニューバー投影（NSStatusItem）の所有者。AppDelegate が起動時に生成し、
/// `AttentionStore`（単一情報源）を SwiftUI（`MenuBarStatusView`）へ橋渡しする。
///
/// 4 態: ①要対応 0＝減光 ◐ ②状態変化の瞬間（`store.transient` が生きている間）＝滲み出しピル
/// ③収縮後＝◐＋件数（waiting+done のみ） ④クリック＝ドロップダウン（`MenuBarDropdown`）。
/// ②の間のクリックだけは該当タブへ直行する（前面化＋focus）。main スレッド規律
/// （AppKit・AttentionStore と同じ）で、monitor / timer / target-action はすべて main で届く。
///
/// ②の開閉は `MenuBarArrivalDriver` が位相として持ち、controller が tween 中だけ 1/60s の
/// ticker を回して「位相を進める → intrinsic を確定させる → `statusItem.length` へ反映」を
/// 同期で撃つ。滞留中は ticker を止める（回るのは最大 2.3 秒＋0.6 秒）。
final class MenuBarController: NSObject {
  private let store: AttentionStore
  private unowned let windowController: WindowController
  private let localization: LocalizationStore
  private let statusItem: NSStatusItem
  /// chrome と同じ実ホルダー（別 NSHostingView root なので Environment は継承されない）。
  /// ピルの状態グリフとドロップダウンの行が、パレットと同じ上書き・フォントで描かれる。
  private let iconResolver: AgentIconResolver
  private let fontResolver: ChromeFontResolver
  private let host: MenuBarItemHostingView
  private let ui = MenuBarUIState()
  private let driver = MenuBarArrivalDriver()
  private var dropdown: MenuBarDropdown?
  private var transientTimer: Timer?
  private var ticker: Timer?
  /// 直近に driver へ渡した到来時刻。同じタブの積み替えも「新しい到来」なのでここで見分ける。
  private var lastArrivedAt: Date?

  init(store: AttentionStore, windowController: WindowController, localization: LocalizationStore) {
    self.store = store
    self.windowController = windowController
    self.localization = localization
    iconResolver = windowController.agentIconResolver
    fontResolver = windowController.fontResolver
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    host = MenuBarItemHostingView(
      rootView: MenuBarStatusView(
        store: store, ui: ui, phase: .closed, iconResolver: windowController.agentIconResolver))
    super.init()

    // button に SwiftUI を貼る（静的 NSImage では②の滲み出しが表現できない）。
    // クリックは button の target/action で受けるため、hosting view はヒットテストを素通しする。
    //
    // サイズは制約でなく statusItem.length へ明示反映する——variableLength の status bar は
    // button 内子ビューの制約を幅に読まず、既定の空 button 幅（実測 16px）へ潰して content を
    // 切り詰める（最小再現スパイクで確定）。intrinsic 変化のたびに length と frame を同期する。
    host.sizingOptions = .intrinsicContentSize
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(statusItemClicked)
      // autoresizing は付けない——button 追随で frame が content より広がると中央寄せになる
      // （幅は `syncItemSize` が intrinsic から組む唯一の経路）。
      button.addSubview(host)
      host.onIntrinsicSizeChange = { [weak self] in
        DispatchQueue.main.async { self?.syncItemSize() }
      }
      syncItemSize()
    }
    // メニューバーはアプリの theme 強制（NSApp.appearance）でなく**システム外観**で描かれる。
    // 強制テーマのままだと明るいメニューバーに dark 用インクを塗って不可視になるため、
    // hosting view の外観をシステム外観へ固定し、切替の配信通知で追従する。
    syncSystemAppearance()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(systemAppearanceChanged),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    syncReduceMotion()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(reduceMotionChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    observeTransient()
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    transientTimer?.invalidate()
    ticker?.invalidate()  // 繰り返しなので、放置すると main runloop に空撃ちが残る
  }

  /// hosting view の intrinsic 幅を statusItem.length へ反映し、**同じ幅で** host の frame を組む。
  ///
  /// frame を `button.bounds` から取ってはいけない——`statusItem.length` の代入が button の
  /// bounds へ届くのは次のレイアウトパスで、幅が縮んだフレームでは古い（広い）bounds が返る。
  /// `NSHostingView` は content より広い frame では content を**中央**に置くため（実測: 46pt の
  /// content を 200pt の host に置くと x=79 から描かれる）、その 1 パスだけピルが中央へ寄り、
  /// 続けて縮むので「中央へ萎んで消える」ように見える。frame を intrinsic に固定すれば、
  /// content と器の幅が常に一致してこのずれ自体が起きない。
  private func syncItemSize() {
    let width = max(host.intrinsicContentSize.width, 1)
    statusItem.length = width
    let height = statusItem.button?.bounds.height ?? NSStatusBar.system.thickness
    host.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 1))
  }

  @objc private func systemAppearanceChanged() {
    DispatchQueue.main.async { [weak self] in self?.syncSystemAppearance() }
  }

  private func syncSystemAppearance() {
    let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }

  @objc private func reduceMotionChanged() {
    DispatchQueue.main.async { [weak self] in self?.syncReduceMotion() }
  }

  private func syncReduceMotion() {
    driver.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  // MARK: - クリック分岐

  @objc private func statusItemClicked() {
    // ②の間のクリック＝該当タブへ直行（前面化＋focus）。ドロップダウンは開かない。
    // 閉じ方は滞留満了と同じ収縮で、尺だけが速い（②を落とすのは閉じ切った `advance`）。
    // 取り下げ済み（閉じかけ）のピルは②としてもう生きていないので、通常のクリックへ落とす。
    if let transient = store.transient, !transient.retracted {
      driver.dismissed(at: Date())
      advance()
      NSApp.activate(ignoringOtherApps: true)
      windowController.window.makeKeyAndOrderFront(nil)
      windowController.focusAttentionTab(tabId: transient.row.tabId)
      closeDropdown()
      return
    }
    if dropdown == nil { showDropdown() } else { closeDropdown() }
  }

  // MARK: - ドロップダウン

  /// ドロップダウンが開いているか。⌘⌘ の宛先分岐（`AppDelegate`）が読む。
  var isDropdownOpen: Bool { dropdown != nil }

  /// ドロップダウンを開く（アイテムクリック・権限ありの global ⌘⌘）。
  /// アイテムが隠れている（ユーザーがメニューバーから外した・溢れた）ときは、錨が画面に無いので
  /// no-op。`button.window` は隠れていても非 nil のまま古い frame を返すので、可視判定は
  /// `isVisible` が持つ（窓の nil 判定はそれ自体では錨の不在を意味しない補助のガード）。
  func showDropdown() {
    guard dropdown == nil, statusItem.isVisible else { return }
    guard let buttonWindow = statusItem.button?.window else { return }
    let d = MenuBarDropdown(
      store: store, localization: localization,
      permissionGranted: CmdDoubleTapMonitor.globalMonitoringPermitted,
      iconResolver: iconResolver, fontResolver: fontResolver)
    d.onSelectRow = { [weak self] row in
      guard let self else { return }
      self.closeDropdown()
      NSApp.activate(ignoringOtherApps: true)  // 行クリック＝orbe 前面化＋タブへ移動
      self.windowController.window.makeKeyAndOrderFront(nil)
      self.windowController.focusAttentionTab(tabId: row.tabId)
    }
    d.onOpenOrbe = { [weak self] in
      guard let self else { return }
      self.closeDropdown()
      NSApp.activate(ignoringOtherApps: true)
      self.windowController.window.makeKeyAndOrderFront(nil)
    }
    d.onPermissionHint = { [weak self] in
      guard let self else { return }
      self.closeDropdown()
      NSApp.activate(ignoringOtherApps: true)
      self.windowController.window.makeKeyAndOrderFront(nil)
      self.windowController.showSettingsPalette()  // 権限状態行は設定パレット root にある
    }
    d.onClose = { [weak self] in
      self?.dropdown = nil
      self?.ui.dropdownOpen = false
    }
    dropdown = d
    ui.dropdownOpen = true
    d.show(anchoredTo: buttonWindow.frame, on: buttonWindow.screen)
  }

  func closeDropdown() {
    dropdown?.close()  // onClose 経由で dropdown = nil / ui.dropdownOpen = false に落ちる
  }

  // MARK: - 一過性表示（②）の到来・滞留・収縮と幅同期

  /// store の変化（transient の到来/消滅・件数）を観測し、driver へ到来と取り下げを伝え、
  /// 期限タイマーを張り直して**アイテム幅を即時同期**する（Observation の標準ループ）。
  /// 幅は SwiftUI の再レイアウトを待ってから読む（layoutSubtreeIfNeeded → syncItemSize）。
  /// invalidateIntrinsicContentSize フックはこの経路の取りこぼし（フォント読み込み等の遅延
  /// サイズ確定）を拾う保険として残す。
  private func observeTransient() {
    withObservationTracking {
      _ = store.transient?.arrivedAt
      _ = store.transient?.expiresAt
      _ = store.transient?.retracted
      _ = store.rows.count
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.syncTransient()
        // SwiftUI の更新適用が次 tick にずれる場合の取りこぼしを塞ぐ（幅同期は冪等）。
        DispatchQueue.main.async { self.syncItemSize() }
        self.observeTransient()
      }
    }
    scheduleTransientExpiry()
  }

  private func syncTransient() {
    let arrivedAt = store.transient?.arrivedAt
    if arrivedAt != lastArrivedAt {
      lastArrivedAt = arrivedAt
      if let arrivedAt {
        // 積み替えも新しい到来（艶が走り直す）。基点は打刻された到来時刻——収縮の満了
        // （`expiresAt`）と同じ時計に揃え、観測の main ホップぶんずれた展開にしない。
        driver.arrived(at: arrivedAt)
      } else {
        driver.closedOut()  // 収縮を撃ち終えて②が落ちた（描く材料が無い）
      }
    } else if store.transient?.retracted == true, !driver.isCollapsing {
      // 取り下げが決まった＝ここから速い収縮で閉じる（滞留満了と同じ動きの尺違い）。
      driver.dismissed(at: Date())
    }
    scheduleTransientExpiry()
    render()
    syncTicker()
  }

  /// 現在の位相を content へ流し、intrinsic を確定させてから `statusItem.length` へ反映する。
  private func render() {
    host.rootView = MenuBarStatusView(
      store: store, ui: ui, phase: driver.phase, iconResolver: iconResolver)
    host.layoutSubtreeIfNeeded()  // 新しい content の intrinsic を確定させてから幅を読む
    syncItemSize()
  }

  /// tween 中だけ回る 1/60s の ticker。位相を進めて幅を追随させ、収縮を撃ち終えたら②を落とす。
  private func startTicker() {
    guard ticker == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      self?.advance()  // main runloop の timer＝main で届く
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  /// ticker の生死は driver の tween 状態そのもの。位相を触ったら必ずこれを撃つ。
  private func syncTicker() {
    if driver.isAnimating { startTicker() } else { stopTicker() }
  }

  private func advance() {
    let collapsed = driver.tick(now: Date())
    // 落とすのは driver が閉じ切った当の到来だけ。収縮の最終フレームに割り込んだ新しい到来を
    // 巻き添えにしない（その到来は observeTransient 経由で driver.arrived へ届く）。
    // 描く前に落とす——閉じ切りの位相は向きを持たないので、②を載せたまま描くと最終フレーム
    // だけ到来時の件数へ戻って見える。
    if collapsed, store.transient?.arrivedAt == lastArrivedAt { store.transient = nil }
    render()
    syncTicker()
  }

  private func scheduleTransientExpiry() {
    transientTimer?.invalidate()
    transientTimer = nil
    // 収縮中・取り下げ済みは張らない——一度閉じ始めたら閉じ切る（満了はもう過ぎており、
    // 張れば 0.1s 床で `transientExpired` に再入して収縮の基点を引き直し、ホバーなら延長すらする）。
    guard let transient = store.transient, !transient.retracted, !driver.isCollapsing
    else { return }
    let interval = max(0.1, transient.expiresAt.timeIntervalSinceNow)
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      self?.transientExpired()  // main runloop の timer＝main で届く
    }
    RunLoop.main.add(timer, forMode: .common)
    transientTimer = timer
  }

  /// 滞留の満了。ホバー中は収縮を先送りし、そうでなければ収縮を撃つ（一度閉じ始めたら閉じ切る
  /// ——収縮中に期限タイマーは張られない）。取り下げ済みは既に閉じかけなので触らない。
  private func transientExpired() {
    guard let transient = store.transient, !transient.retracted else { return }
    if ui.itemHovered {
      // ホバー中は収縮しない（延長）。ホバーが外れた後の余韻ぶんだけ先送りする。
      store.transient?.expiresAt = Date().addingTimeInterval(2)
      return
    }
    driver.expired(at: Date())
    advance()
  }
}

/// メニューバー投影の UI 状態（controller と `MenuBarStatusView` の共有）。
@Observable final class MenuBarUIState {
  /// ドロップダウン表示中（④）＝ピル地を accent tint に。
  var dropdownOpen = false
  /// メニューバーアイテムをホバー中（収縮の延長判定に使う）。view が書き controller が読む。
  /// ピルは全態で常設なので、述語は「②のホバー」ではなく「アイテムのホバー」——②が生きて
  /// いるかは読み手（`transientExpired`）が見る。載せたまま②が到来しても延長が効く。
  var itemHovered = false
}

/// メニューバーアイテム用の hosting view。クリックを NSStatusBarButton（背後の target/action）へ
/// 素通しし（ホバー〔tracking area 由来〕は生きたまま、ヒットテストだけ無効化）、
/// intrinsic サイズの変化を controller へ通知する（statusItem.length の明示反映に使う）。
private final class MenuBarItemHostingView: NSHostingView<MenuBarStatusView> {
  var onIntrinsicSizeChange: (() -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onIntrinsicSizeChange?()
  }
}
