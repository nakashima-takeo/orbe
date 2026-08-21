import AppKit
import XCTest

@testable import Orbe

/// 保存ファイルからの起動時復元（`WindowController.restore(from:)`）と、その裏返しである
/// デバウンス保存の契約を、実 `WindowController` で固定する。
///
/// 壊れると何が起きるか。復元が 1 フィールドでも落とすと、次の保存がその欠けた姿でディスクを
/// 上書きする——分割比・cwd・エージェントセッション・明示タイトル・workspace
/// 上書き設定・最終使用時刻のどれかが、再起動 1 回で永久に消える。index のクランプが外れれば
/// 範囲外 index で配列を引いて起動時に crash する。ウィンドウサイズの記憶に表示クランプ値が
/// 回り込めば、小さい画面で一度開いただけで大画面用のサイズが失われ二度と戻らない。デバウンスが
/// 早発すれば cwd 報告のたびディスクへ書き、遅発を取り消せなければ終了時の確定保存が後から
/// 古い値で上書きされる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**
/// （GhosttyKit 必須）。ただし surface（＝実シェル）が起きるのはアクティブ workspace に
/// タブがある fixture だけ——非アクティブ workspace の `TerminalController` はオブジェクトとして
/// 生きるが window に載らないので surface は生まれない。等値で見たい検証はこの休眠側に寄せる。
final class WindowControllerRestoreTests: OrbeTestCase {

  private let stampBackground = Date(timeIntervalSinceReferenceDate: 700_000_000)
  private let stampFront = Date(timeIntervalSinceReferenceDate: 800_000_000)

  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動する（未選択だと初回言語選択 overlay が前に出る）。
    // PATH キャッシュも張る——無ければ resume 解決がログインシェルを同期 spawn して数秒待つ。
    AppStatePersistence.save(
      AppStateFile(cachedShellPath: "/usr/bin:/bin", preferredLanguage: "ja"))
  }

  // MARK: - fixture 組み立て

  /// タブ `count` 枚の workspace state（タブは素の葉・区別できる明示タイトル付き）。
  private func state(_ name: String, activeTab: Int, tabs count: Int) -> WorkspaceState {
    WorkspaceState(
      name: name, rootPath: "/tmp", activeTab: activeTab,
      tabs: (0..<count).map {
        TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: "t\($0)")
      })
  }

  /// 上書き設定層（型の異なる 3 項目で、1 項目だけ運ぶ実装と区別する）。
  private func overrideLayer() -> SettingsLayer {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = 18
    layer[SettingKeys.theme] = .dark
    layer[SettingKeys.defaultAgent] = "codex"
    return layer
  }

  /// ディスクへ書いてから復元済み `WindowController` を返す。
  private func launch(
    activeWorkspace: Int, _ workspaces: [WorkspaceState], windowSize: WindowSize? = nil
  ) -> WindowController {
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
        workspaces: workspaces, windowSize: windowSize))
    return WindowController()
  }

  /// main runloop を `seconds` 回す（デバウンスの締切をまたぐ）。main キューは締切順に捌かれるため、
  /// 1 秒のデバウンスは 1.5 秒待ちより必ず先に発火する＝待ち時間の伸縮に頼らず決定的。
  private func spinMainRunLoop(_ seconds: TimeInterval) {
    let done = expectation(description: "main runloop \(seconds)s")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 2.0)
  }

  // MARK: - 保存 → 復元 → 再保存のラウンドトリップ

  /// アクティブが 0 タブ（休眠）なら surface が 1 つも起きず、`WorkspacesFile` が**完全に等値**で戻る。
  /// 分割比・cwd・エージェントセッション・明示タイトル・上書き設定・最終使用時刻・
  /// ウィンドウサイズを 1 本で通す——どれか 1 つを復元が落とせばここで落ちる。
  ///
  /// 0 タブでも前面 workspace として利用した時刻は進む。一方、タブの起床状態は
  /// 永続化しないため、再保存で変わるのはアクティブ側の `lastUsedAt` だけ。
  func testRoundTripForEmptyActiveWorkspaceAdvancesOnlyLastUsedAt() throws {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "dormant", rootPath: "/tmp/dormant", activeTab: 0, tabs: [],
          lastUsedAt: stampBackground),
        WorkspaceState(
          name: "loaded", rootPath: "/tmp/loaded", activeTab: 1,
          tabs: [
            TabState(
              tree: .split(
                vertical: true, ratio: 0.3,
                first: .leaf(cwd: "/work/api", agent: nil),
                second: .leaf(
                  cwd: "/work/web",
                  // resume 対応 CLI ＋ 安全文字集合の sessionId。解決できないと素のシェルへ
                  // 落ちて agent が消える（＝ここが等値にならない）。
                  agent: AgentSession(command: "claude", sessionId: "web-1"))),
              explicitTitle: "api"),
            TabState(tree: .leaf(cwd: "/work/docs", agent: nil), explicitTitle: nil),
          ],
          lastUsedAt: stampFront, settingsOverride: overrideLayer()),
      ],
      windowSize: WindowSize(width: 700, height: 400))
    WorkspacePersistence.save(original)

    let before = Date()
    let wc = WindowController()
    XCTAssertTrue(wc.current.tabs.isEmpty)
    XCTAssertFalse(wc.current.activated, "0 タブは前面表示中でも materialize 済みではない")
    wc.flushSave()

    let saved = try XCTUnwrap(WorkspacePersistence.load())
    let stamp = try XCTUnwrap(saved.workspaces[0].lastUsedAt)
    XCTAssertGreaterThanOrEqual(stamp, before, "0 タブでも workspace の前面利用は MRU を進める")
    var expected = original
    expected.workspaces[0].lastUsedAt = stamp
    XCTAssertEqual(saved, expected, "起床状態は永続化せず、進むのは前面利用の lastUsedAt だけ")
  }

  /// タブを mount する通常形でも、動くのはアクティブ workspace の `lastUsedAt` だけ。
  /// 刻印は MRU の仕様（アクティブ化＝「使った」時刻）なので名指しで assert し、それ以外は
  /// 背景 workspace も含めて保存値のまま等値で見る。
  func testRoundTripWithMountedTabOnlyAdvancesActiveLastUsedAt() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,
      workspaces: [
        WorkspaceState(
          name: "background", rootPath: "/tmp/bg", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: "/work/bg", agent: nil), explicitTitle: "bg")],
          lastUsedAt: stampBackground),
        WorkspaceState(
          name: "front", rootPath: home, activeTab: 0,
          tabs: [
            TabState(tree: .leaf(cwd: home, agent: nil), explicitTitle: "front")
          ],
          lastUsedAt: stampFront, settingsOverride: overrideLayer()),
      ],
      windowSize: WindowSize(width: 700, height: 400))
    WorkspacePersistence.save(original)
    let before = Date()

    let wc = WindowController()
    wc.flushSave()

    let saved = try XCTUnwrap(WorkspacePersistence.load())
    let stamp = try XCTUnwrap(saved.workspaces[1].lastUsedAt, "アクティブ workspace には刻印が残る")
    XCTAssertGreaterThanOrEqual(stamp, before, "アクティブ化でアクティブ workspace の lastUsedAt が now へ進む")

    var expected = original
    expected.workspaces[1].lastUsedAt = stamp
    XCTAssertEqual(saved, expected, "進むのは lastUsedAt だけ——mount してもモデルは他に 1 つも動かない")
  }

  /// 旧バージョン（v2＝タブが素の `PaneNode`）のファイルからの起動は、タブ構成を失わずに
  /// 現行バージョンで書き直す。壊れると v3 導入後に一度も起動していないユーザーが、起動 1 回で
  /// 全タブを失う（次の保存が空の姿でディスクを上書きする）。
  func testLaunchFromLegacyV2FileRewritesToCurrentVersion() throws {
    try Data(
      """
      {"version":2,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/","activeTab":0,"tabs":[{"leaf":{"cwd":"/r/a"}}]}]}
      """.utf8
    ).write(to: try workspacesFile())

    let wc = WindowController()
    wc.flushSave()

    let saved = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(saved.version, WorkspacePersistence.version, "起動 1 回で現行バージョンへ書き直す")
    XCTAssertEqual(
      saved.workspaces[0].tabs[0].tree, .leaf(cwd: "/r/a", agent: nil), "v2 のタブ構成を失わない")
  }

  /// 保存分割比は mount 後の**実レイアウト**へ適用される。上の 2 本は非 mount 側なので、
  /// `WorkspaceSplitView.ratio` が bounds 0 で保存値をそのまま返す fallback しか通らない
  /// ——`layout()` の `setPosition` が消えても等値は保たれてしまう。ここが唯一その適用を見る。
  /// 壊れると復元した分割が全部 50/50 で開く（保存値は往復するので気づけない）。
  func testRestoredSplitRatioIsAppliedToMountedLayout() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let wc = launch(
      activeWorkspace: 0,
      [
        WorkspaceState(
          name: "front", rootPath: home, activeTab: 0,
          tabs: [
            TabState(
              tree: .split(
                vertical: true, ratio: 0.3,
                first: .leaf(cwd: home, agent: nil), second: .leaf(cwd: home, agent: nil)),
              explicitTitle: nil)
          ])
      ],
      windowSize: WindowSize(width: 700, height: 400))
    wc.window.layoutIfNeeded()

    // 実レイアウトを通ったことを先に確定させる——bounds 0 なら ratio は保存値をそのまま返し、
    // 下の assert が恒真になって唯一の適用検証が無言で死ぬ。
    let split = try XCTUnwrap(
      wc.current.tabs[wc.current.active].rootContainer.subviews.first as? WorkspaceSplitView,
      "復元したタブの root は分割ビュー")
    XCTAssertGreaterThan(split.bounds.width, 0, "分割ビューが実フレームを持つ（0 なら下の検証は恒真）")

    guard case .split(_, let ratio, _, _) = wc.current.tabs[wc.current.active].snapshot() else {
      return XCTFail("復元したタブは分割木のまま")
    }
    XCTAssertEqual(ratio, 0.3, accuracy: 0.02, "保存分割比が実フレームへ適用される（未適用なら 0.5 になる）")
  }

  // MARK: - index のクランプ（範囲外の保存値で起動しても配列を踏み外さない）

  /// 保存 activeWorkspace が workspace 数を超えていたら最終 index へ丸める。
  func testActiveWorkspaceIndexClampsToLast() {
    let wc = launch(
      activeWorkspace: 7, [state("a", activeTab: 0, tabs: 0), state("b", activeTab: 0, tabs: 0)])
    XCTAssertEqual(wc.activeWorkspace, 1, "範囲超の activeWorkspace は最終 index へ丸める")
    XCTAssertEqual(wc.window.title, "b", "丸めた先の workspace が実際にアクティブになる")
  }

  /// 保存 activeWorkspace が負値なら 0 へ丸める。
  func testNegativeActiveWorkspaceIndexClampsToZero() {
    let wc = launch(
      activeWorkspace: -3, [state("a", activeTab: 0, tabs: 0), state("b", activeTab: 0, tabs: 0)])
    XCTAssertEqual(wc.activeWorkspace, 0, "負値の activeWorkspace は 0 へ丸める")
    XCTAssertEqual(wc.window.title, "a", "丸めた先の workspace が実際にアクティブになる")
  }

  /// 各 workspace の activeTab は自分のタブ数へ丸める（0 タブなら 0）。
  /// アクティブを 0 タブ（休眠）にして、丸めそのものは surface を起こさずに観測する。
  func testActiveTabIndexClampsWithinEachWorkspace() {
    let wc = launch(
      activeWorkspace: 0,
      [
        state("dormant", activeTab: 5, tabs: 0),
        state("over", activeTab: 9, tabs: 2),
        state("under", activeTab: -4, tabs: 2),
      ])
    XCTAssertEqual(
      wc.workspaces[0].active, 0, "0 タブ workspace の activeTab は 0（再アクティブ化で index 0 を選べる）")
    XCTAssertEqual(wc.workspaces[1].active, 1, "範囲超の activeTab は最終タブへ丸める")
    XCTAssertEqual(wc.workspaces[2].active, 0, "負値の activeTab は 0 へ丸める")
  }

  /// アクティブ workspace の activeTab の丸めは、後続の `select()` に上書きされない
  /// （丸め値のまま mount されるので、範囲外 index でタブ配列を引く経路が残らない）。
  func testActiveTabClampSurvivesActivation() {
    let wc = launch(activeWorkspace: 0, [state("front", activeTab: 9, tabs: 2)])
    XCTAssertEqual(wc.current.active, 1, "アクティブ workspace でも丸めた最終タブが選ばれたまま")
  }

  // MARK: - ウィンドウサイズ（記憶はクランプ前・表示はクランプ後）

  /// 記憶するのはユーザー意図サイズ（クランプ前）。表示クランプが記憶へ回り込むと、
  /// 小さい画面で一度開いただけで大画面用のサイズが消える。画面の有無に関わらず成立する。
  func testOversizedWindowSizeIsRememberedUnclamped() throws {
    let huge = WindowSize(width: 99_999, height: 99_999)
    let wc = launch(activeWorkspace: 0, [state("dormant", activeTab: 0, tabs: 0)], windowSize: huge)

    wc.flushSave()

    XCTAssertEqual(
      WorkspacePersistence.load()?.windowSize, huge, "記憶はユーザー意図サイズのまま（表示クランプで削られない）")
  }

  /// 表示は起動時画面の visibleFrame へ収める（画面からはみ出した状態で開かない）。
  func testRestoredWindowFitsVisibleFrame() throws {
    let wc = launch(
      activeWorkspace: 0, [state("dormant", activeTab: 0, tabs: 0)],
      windowSize: WindowSize(width: 99_999, height: 99_999))

    guard let visible = (wc.window.screen ?? NSScreen.main)?.visibleFrame.size else {
      throw XCTSkip("画面を持たない環境では表示クランプ自体が起きない（記憶側は別テストが無条件に見る）")
    }
    XCTAssertLessThanOrEqual(wc.window.frame.width, visible.width, "復元幅は画面の可視領域に収まる")
    XCTAssertLessThanOrEqual(wc.window.frame.height, visible.height, "復元高さは画面の可視領域に収まる")
  }

  // MARK: - 保存のデバウンス

  /// `scheduleSave` は即書かず、締切を過ぎてから 1 回書く（高頻度な cwd 報告をまとめるため）。
  /// アクティブを 0 タブにするのは、ペイン由来の予期しない保存予約を混ぜないため。
  func testScheduleSaveWritesOnlyAfterDebounce() throws {
    let wc = launch(activeWorkspace: 0, [state("dormant", activeTab: 0, tabs: 0)])
    wc.flushSave()  // 起動由来の予約を確定させて場を空にする
    let saved = try workspacesFile()
    try FileManager.default.removeItem(at: saved)

    wc.scheduleSave()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: saved.path), "予約した直後は書かない（変化をまとめる）")

    spinMainRunLoop(1.5)
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "締切を過ぎたら書く")
  }

  /// `flushSave` は待ち中の予約を取り消す。取り消せないと、終了時に確定保存した後から
  /// 古いスナップショットが遅れて上書きする。
  func testFlushSaveCancelsPendingDebounce() throws {
    let wc = launch(activeWorkspace: 0, [state("dormant", activeTab: 0, tabs: 0)])
    wc.scheduleSave()
    wc.flushSave()
    let saved = try workspacesFile()
    try FileManager.default.removeItem(at: saved)

    spinMainRunLoop(1.5)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: saved.path), "flushSave 後に取り残された予約は書かない")
  }
}
