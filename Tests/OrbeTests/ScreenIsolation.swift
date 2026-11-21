import AppKit

/// 利用者の画面と前面の隔離。テストは、画面に窓を出さず、アプリを前面にせず、本物のシートを出さない。
///
/// 画面と前面は、永続ファイルやクリップボードのように別の場所へ向け直せない実環境なので、隔離は「破ったテストを落とす」
/// 形で持つ。テスト 1 件の始まりの状態を控え、テストがランループを回すたびと、終わり（`tearDown` の後）に、テストの
/// 実行体の状態を見て、始まりと比べる。落とすのは次の 4 つ。
///
/// - アクティベーションポリシーが変わった（始まりと終わりだけで見る）。
/// - アプリが前面になった。
/// - 並んでいて（ordered-in）、ディスプレイの範囲と面積を持って重なる窓が増えた。画面外へ並べた窓（`placeOffscreen`）と、
///   大きさ 0 の窓は、重なる窓に数えない。
/// - 本物のシートが出た（`NSWindow.willBeginSheetNotification`）。`OrbeWindowFake` が受けたシートは、この通知を出さない。
///
/// 終わりだけを見ないのは、テストの窓が、終わりより前に下ろされるか解放されるため。
///
/// 仕組みの性質から、届かない範囲が在る。
///
/// - 見るのは、ランループの切れ目と終わりだけ。ランループを 1 度も回さないうちに並べて、下ろすか解放した窓には届かない。
///   1 件の中で変えて戻したアクティベーションポリシーにも届かない。前面にする要求がテストの終わりより後に届くと、落ちるのは
///   次のテストになる。
/// - 見るのは、テストの実行体だけ。ほかのアプリを起動する・前面にする操作（`NSWorkspace.shared.open` など）には届かない。
/// - 落とすのは、テスト 1 件が戻った後に、ふつうの失敗を記録する形。戻らないテスト（モーダルで止まるもの）、skip した
///   テスト、失敗を期待すると宣言したテスト（`XCTExpectFailure`）は落ちない。クラスの `setUp`・`tearDown` は包まない。
/// - 変わった状態を戻さず、状態が戻るのを待たない。破ったテストの後は、同じ実行の残りのテストが、変わった状態のまま
///   走る（落ちるのは破ったテストだけ）。
/// - 包むのは、`OrbeTestCase` を継承するテストだけ。
///
/// 前面になった通知（`NSApplication.didBecomeActiveNotification`）では見ない。この通知を手で出して、前面と背面で
/// 分かれる挙動を確かめるテストが在る。
@MainActor
final class ScreenIsolation {
  /// テストの実行体が、利用者の画面と前面に現れている状態。
  struct State {
    var policy: NSApplication.ActivationPolicy
    var isActive: Bool
    /// 並んでいて、ディスプレイの範囲と面積を持って重なる窓（窓と、失敗の文言に出す説明）。
    var windowsOnDisplays: [ObjectIdentifier: String]

    /// ポリシーは OS への問い合わせで、ランループが回るたびに読むには重い。回るたびに見るときは、読まずに始まりの値を渡す。
    static func current(
      policy: NSApplication.ActivationPolicy = NSApplication.shared.activationPolicy()
    ) -> State {
      let app = NSApplication.shared
      var windows: [ObjectIdentifier: String] = [:]
      for window in app.windows where window.isShownOnADisplay {
        windows[ObjectIdentifier(window)] = "\(type(of: window)) \(window.frame)"
      }
      return State(policy: policy, isActive: app.isActive, windowsOnDisplays: windows)
    }

    /// `start` からこの状態までの違反。
    func breaches(since start: State) -> [String] {
      var breaches: [String] = []
      if policy != start.policy {
        breaches.append("アクティベーションポリシーが変わった（\(start.policy.name) → \(policy.name)）")
      }
      if isActive, !start.isActive { breaches.append("アプリが前面になった") }
      let added = windowsOnDisplays.filter { start.windowsOnDisplays[$0.key] == nil }
      for window in added.values.sorted() {
        breaches.append(
          "窓がディスプレイの範囲と重なって並んだ（\(window)）。窓は並べない。マウスの配送が要るテストだけ placeOffscreen を通す")
      }
      return breaches
    }
  }

  private let start = State.current()
  private var breaches: [String] = []
  private var sheetObserver: NSObjectProtocol?
  private var runLoopObserver: CFRunLoopObserver?

  init() {
    sheetObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willBeginSheetNotification, object: nil, queue: nil
    ) { [weak self] notification in
      let parent = String(describing: type(of: notification.object as AnyObject))
      MainActor.assumeIsolated {
        self?.note(
          "本物のシートが出た（親の窓: \(parent)）。確認を出すコードを通るテストは、エディターの面を OrbeWindowFake に載せ、"
            + "WindowController には OrbeWindowFake を渡す")
      }
    }
    let onPass: (CFRunLoopObserver?, CFRunLoopActivity) -> Void = { [weak self] _, _ in
      MainActor.assumeIsolated { self?.observe(readingPolicy: false) }
    }
    let activities: CFRunLoopActivity = [.beforeWaiting, .exit]
    runLoopObserver = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0, onPass)
    CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
  }

  private func note(_ breach: String) {
    if !breaches.contains(breach) { breaches.append(breach) }
  }

  private func observe(readingPolicy: Bool) {
    let now = readingPolicy ? State.current() : State.current(policy: start.policy)
    for breach in now.breaches(since: start) { note(breach) }
  }

  /// テストの終わりに呼ぶ。見つけた違反を、失敗の文言で返す。
  func finish() -> [String] {
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    if let runLoopObserver { CFRunLoopObserverInvalidate(runLoopObserver) }
    observe(readingPolicy: true)
    return breaches.map { "画面と前面の隔離: \($0)" }
  }
}

extension NSWindow {
  /// 並んでいて（ordered-in）、枠がどれかのディスプレイの範囲と面積を持って重なるか。画面外へ並べた窓と、大きさ 0 の窓では
  /// false。`intersects` は、相手の中に在る大きさ 0 の矩形も重なると答えるので、交わりの幅と高さで見る。
  var isShownOnADisplay: Bool {
    isVisible
      && NSScreen.screens.contains { screen in
        let common = screen.frame.intersection(frame)
        return common.width > 0 && common.height > 0
      }
  }
}

extension NSApplication.ActivationPolicy {
  fileprivate var name: String {
    switch self {
    case .regular: "regular"
    case .accessory: "accessory"
    case .prohibited: "prohibited"
    @unknown default: "rawValue \(rawValue)"
    }
  }
}
