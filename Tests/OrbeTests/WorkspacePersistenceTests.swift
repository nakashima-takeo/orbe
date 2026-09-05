import AppKit
import XCTest

@testable import Orbe

/// workspace 永続のロジック検証（libghostty 非依存）。
/// 復元単位の組み立ては TerminalTab を window 未接続で操作すれば surface を起こさず検証できる。
final class WorkspacePersistenceTests: OrbeTestCase {

  /// テストの復元では resume を起こさない（agent 付きタブの検証のみ）。
  private let noResume: TerminalTab.ResumeSpawn = { _ in nil }

  // MARK: - スキーマ Codable 往復

  func testSchemaCodableRoundTrip() throws {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,
      workspaces: [
        WorkspaceState(
          name: "default", rootPath: "/Users/x", activeTab: 0,
          tabs: [TabState(cwd: "/a", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "api", rootPath: "/srv", activeTab: 1,
          tabs: [
            TabState(cwd: "/b", agent: nil, explicitTitle: "b"),
            TabState(
              cwd: "/c", agent: AgentSession(command: "claude", sessionId: "s"),
              explicitTitle: nil),
          ]),
      ])
    let data = try JSONEncoder().encode(file)
    let back = try JSONDecoder().decode(WorkspacesFile.self, from: data)
    XCTAssertEqual(back, file, "Codable 往復で構成が一致")
  }

  /// タブは平坦な `{cwd, agent?, explicitTitle?}` で書く（外部契約の形）。
  func testTabStateWireShape() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try enc.encode(
      TabState(
        cwd: "/work/api", agent: AgentSession(command: "claude", sessionId: "s-1"),
        explicitTitle: "api"))
    XCTAssertEqual(
      String(data: data, encoding: .utf8),
      #"{"agent":{"command":"claude","sessionId":"s-1"},"cwd":"/work/api","explicitTitle":"api"}"#)
  }

  func testVersionMismatchIsRejectedOnLoad() throws {
    let tmp = try workspacesFile()
    let future = WorkspacesFile(
      version: 999, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "a", rootPath: "/", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(future).write(to: tmp)
    XCTAssertNil(WorkspacePersistence.load(), "非互換 version は load で nil（呼び出し側が既定 fallback）")
  }

  // MARK: - ウィンドウサイズ（条件3: 旧 JSON 後方互換・往復）

  /// windowSize フィールドが欠落した旧 JSON も load 成功し、windowSize は nil（既定 800×500 へ）。
  func testLegacyJSONWithoutWindowSizeLoads() throws {
    let tmp = try workspacesFile()
    let legacy = """
      {"version":2,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/","activeTab":0,"tabs":[{"leaf":{}}]}]}
      """
    try Data(legacy.utf8).write(to: tmp)
    let loaded = WorkspacePersistence.load()
    XCTAssertNotNil(loaded, "windowSize 欠落の旧 JSON も load 成功（後方互換）")
    XCTAssertNil(loaded?.windowSize, "欠落時 windowSize は nil（既定サイズへ fallback）")
  }

  /// windowSize がディスク往復で保たれる。
  func testWindowSizeRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ],
      windowSize: WindowSize(width: 1024, height: 768))
    WorkspacePersistence.save(original)
    XCTAssertEqual(WorkspacePersistence.load(), original, "windowSize がディスク往復で保たれる")
  }

  // MARK: - 頑健性（条件4: 壊れた JSON は load で nil）

  /// 不正な JSON バイト列を置いても decode 失敗で nil（クラッシュしない）。
  func testCorruptJSONIsRejectedOnLoad() throws {
    let tmp = try workspacesFile()
    try Data("{ this is not valid json ]".utf8).write(to: tmp)
    XCTAssertNil(WorkspacePersistence.load(), "壊れた JSON は load で nil（呼び出し側が既定 fallback）")
  }

  /// 構造は JSON として妥当だがスキーマ不一致（必須キー欠落）でも nil。
  func testSchemaMismatchIsRejectedOnLoad() throws {
    let tmp = try workspacesFile()
    try Data(#"{"foo": 1, "bar": [1,2,3]}"#.utf8).write(to: tmp)
    XCTAssertNil(WorkspacePersistence.load(), "スキーマ不一致は load で nil")
  }

  /// workspaces が空配列の妥当 JSON も nil（既定 1 workspace へ fallback させる）。
  func testEmptyWorkspacesIsRejectedOnLoad() throws {
    let tmp = try workspacesFile()
    let empty = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0, workspaces: [])
    try JSONEncoder().encode(empty).write(to: tmp)
    XCTAssertNil(WorkspacePersistence.load(), "空 workspaces は load で nil")
  }

  // MARK: - 実ファイルへの save → load 往復（条件1+3: ディスク経由で全項目が保たれる）

  func testSaveThenLoadFileRoundTrip() throws {
    let tmp = try workspacesFile()
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,
      workspaces: [
        WorkspaceState(
          name: "default", rootPath: "/Users/me", activeTab: 0,
          tabs: [TabState(cwd: "/Users/me/a", agent: nil, explicitTitle: "ed")]),
        WorkspaceState(
          name: "api", rootPath: "/srv/api", activeTab: 1,
          tabs: [
            TabState(cwd: "/srv/api", agent: nil, explicitTitle: nil),
            TabState(cwd: "/srv/api/x", agent: nil, explicitTitle: nil),
          ]),
      ])
    WorkspacePersistence.save(original)

    XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "save で実ファイルが生成される")
    let reloaded = WorkspacePersistence.load()
    XCTAssertEqual(
      reloaded, original, "ディスク経由で名前・rootPath・activeTab・cwd・activeWorkspace が一致")
  }

  /// エージェントセッション（command + sessionId）がディスク往復で保たれる。
  func testAgentSessionRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [
            TabState(
              cwd: "/p",
              agent: AgentSession(command: "claude", sessionId: "27d05777-57b4-4baa-9532-bc4cac"),
              explicitTitle: nil),
            TabState(cwd: "/q", agent: nil, explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "agent セッション(command+sessionId)と agent 無しタブの混在がディスク往復で保たれる")
  }

  // MARK: - 復元単位（TabState）の組み立て

  /// 復元単位（tabState）は cwd だけでなく明示タイトルも載せる——起動時復元と
  /// ⇧⌘T が共有する契約なので、どちらか 1 つ落ちると片方だけ静かに壊れる。
  func testTabStateCarriesCwdAndTitle() {
    let state = TabState(cwd: "/work/api", agent: nil, explicitTitle: "api")
    let tab = TerminalTab(restoring: state, resumeSpawn: noResume)
    XCTAssertEqual(tab.tabState(), state, "tabState は cwd と明示タイトルを一括で載せる")
  }

  func testRestoreRoundTripPreservesCwd() {
    let state = TabState(cwd: "/home/me/project", agent: nil, explicitTitle: nil)
    let tab = TerminalTab(restoring: state, resumeSpawn: noResume)
    XCTAssertEqual(tab.tabState(), state, "cwd が復元値として保たれる")
  }

  // MARK: - エージェントセッションの復元

  /// agent 付きタブは消費（materialize 開始）時に resumeSpawn へ解決を依頼し、起動指示を確定する。
  /// tabState は休眠中も消費後も agent セッションを保つ（再起動往復が冪等）。
  func testRestoreAgentTabResolvesResumeAndPreservesAgent() {
    var captured: AgentSession?
    let state = TabState(
      cwd: "/w", agent: AgentSession(command: "claude", sessionId: "abc-123"), explicitTitle: nil)
    let tab = TerminalTab(
      restoring: state,
      resumeSpawn: { session in
        captured = session
        return ("claude --resume abc-123", ["PATH": "/usr/bin"])
      })
    XCTAssertNil(captured, "resume 解決は復元時ではなく消費時")
    XCTAssertEqual(tab.tabState(), state, "休眠のままの tabState も agent セッションを保つ")

    tab.recordMaterializationStarted()
    XCTAssertEqual(
      captured, AgentSession(command: "claude", sessionId: "abc-123"),
      "消費時に resumeSpawn へ解決を依頼する")
    XCTAssertEqual(tab.surface.initialCommand, "claude --resume abc-123", "解決した起動指示が spawn に効く")
    XCTAssertEqual(tab.surface.initialEnv["PATH"], "/usr/bin")
    XCTAssertEqual(tab.surface.initialEnv["ORBE_TAB"], String(tab.id), "runtime 契約の env も乗る")
    XCTAssertEqual(tab.tabState(), state, "消費後の tabState も agent セッションを保つ（冪等）")
  }

  /// resume を解決できなければ消費時に素のシェルへ落ち、以後の tabState に agent は付かない。
  /// セッション記録そのものは休眠のあいだ保持される（resume 可否は消費まで判定しない）。
  func testRestoreAgentTabFallsBackToShellWhenUnresolved() {
    let state = TabState(
      cwd: "/w", agent: AgentSession(command: "unknown", sessionId: "x"), explicitTitle: nil)
    let tab = TerminalTab(restoring: state, resumeSpawn: noResume)
    XCTAssertEqual(tab.tabState(), state, "休眠のあいだセッション記録は保持される")

    tab.recordMaterializationStarted()
    XCTAssertEqual(tab.agentSlot, .none, "解決不可なら消費で素のシェルへ落ちる")
    XCTAssertNil(tab.surface.initialCommand)
    XCTAssertEqual(
      tab.tabState(), TabState(cwd: "/w", agent: nil, explicitTitle: nil),
      "素シェル化後の tabState に agent は付かない")
  }

  /// agent が command だけ（sessionId キー欠落）の永続ファイルも読め、sessionId は nil になる。
  /// decode を厳格化すると `load()` が全体 nil に倒れ、ユーザーの workspace 構成が既定で潰され
  /// 原本が quarantine される——欠落キーは常に緩和方向（エラーではなく nil）で受ける。
  func testAgentWithoutSessionIdKeyLoadsAsNilIdentity() throws {
    let tmp = try workspacesFile()
    let json = """
      {"version":4,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/r","activeTab":0,"tabs":[\
      {"cwd":"/r/a","agent":{"command":"claude"}}]}]}
      """
    try Data(json.utf8).write(to: tmp)

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "sessionId キー欠落で全構成を失わない")
    XCTAssertEqual(
      loaded.workspaces[0].tabs[0],
      TabState(
        cwd: "/r/a", agent: AgentSession(command: "claude", sessionId: nil), explicitTitle: nil),
      "欠落キーは nil として読む（CLI 名の記録は残る）")
    XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "原本を quarantine へ退避しない")
  }

  /// sessionId を持たない同一性は、休眠でも稼働中でも tabState に書かない。resume 不能な記録を
  /// ディスクへ増やすと、次の起動で必ず素シェル化する死にチケットが永続し、⇧⌘T のゲートも
  /// 誤って通り始める。
  func testTabStateDropsIdentitiesWithoutASessionId() {
    let dormant = TerminalTab(
      restoring: TabState(
        cwd: "/w", agent: AgentSession(command: "claude", sessionId: nil), explicitTitle: nil),
      resumeSpawn: noResume)
    XCTAssertNil(dormant.tabState().agent, "sessionId 欠落のチケットは保存しない")

    let live = TerminalTab(cwd: "/tmp")
    setReportedState(live, "working", command: "claude")
    XCTAssertEqual(
      live.agentSlot.session, AgentSession(command: "claude", sessionId: nil),
      "前提: 報告が sessionId を運ぶ前の稼働")
    XCTAssertNil(live.tabState().agent, "同一性が未確定の稼働も保存しない")
  }

  // MARK: - ① 明示タイトル（TabState）の永続

  /// explicitTitle がディスク往復で保たれる。
  func testExplicitTitleRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [
            TabState(cwd: "/p", agent: nil, explicitTitle: "build"),
            TabState(cwd: "/q", agent: nil, explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "明示タイトルあり/なしの混在がディスク往復で保たれる")
  }

  // MARK: - 旧形式（v2 / v3）の平坦化移行

  /// 旧 v2 JSON（version:2・タブ＝素の分割ツリー）は load() が現行形式へ平坦化して受理する。
  /// 起動を通した現行バージョンへの書き直しは
  /// `WindowControllerRestoreTests.testLaunchFromLegacyV2FileRewritesToCurrentVersion` が持つ。
  func testLegacyV2FileLoadsFlattened() throws {
    let tmp = try workspacesFile()
    let v2 = """
      {"version":2,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/r","activeTab":0,"tabs":[{"leaf":{"cwd":"/r/a"}}]}]}
      """
    try Data(v2.utf8).write(to: tmp)

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "v2 も load が受理する")
    XCTAssertEqual(loaded.version, WorkspacePersistence.version, "読み込み時点で現行形式へ写す")
    XCTAssertEqual(
      loaded.workspaces[0].tabs, [TabState(cwd: "/r/a", agent: nil, explicitTitle: nil)],
      "既存タブ構成（cwd）を失わず、旧 v2 タブは explicitTitle=nil")
  }

  /// 分割ツリーは葉ごとに 1 タブへ深さ優先順で展開する。明示タイトルは先頭の葉へ、
  /// `activeTab` は旧アクティブタブの先頭葉の新 index へ写す。
  func testLegacyV3SplitTreeFlattensLeavesInDepthFirstOrder() throws {
    let tmp = try workspacesFile()
    let v3 = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/r","activeTab":1,"tabs":[\
      {"tree":{"leaf":{"cwd":"/a"}},"explicitTitle":"first"},\
      {"tree":{"split":{"vertical":true,"ratio":0.4,\
      "first":{"leaf":{"cwd":"/b","agent":{"command":"claude","sessionId":"s-b"}}},\
      "second":{"split":{"vertical":false,"ratio":0.5,\
      "first":{"leaf":{"cwd":"/c"}},"second":{"leaf":{"cwd":"/d"}}}}}},"explicitTitle":"api"},\
      {"tree":{"leaf":{"cwd":"/e"}}}]}]}
      """
    try Data(v3.utf8).write(to: tmp)

    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    let ws = loaded.workspaces[0]
    XCTAssertEqual(
      ws.tabs,
      [
        TabState(cwd: "/a", agent: nil, explicitTitle: "first"),
        TabState(
          cwd: "/b", agent: AgentSession(command: "claude", sessionId: "s-b"), explicitTitle: "api"),
        TabState(cwd: "/c", agent: nil, explicitTitle: nil),
        TabState(cwd: "/d", agent: nil, explicitTitle: nil),
        TabState(cwd: "/e", agent: nil, explicitTitle: nil),
      ], "葉の順（深さ優先）・明示タイトルは先頭の葉だけ・agent は葉ごと")
    XCTAssertEqual(ws.activeTab, 1, "旧アクティブ（index 1）の先頭葉が新 index 1")
  }

  /// 旧アクティブタブより前に分割タブがあれば、その葉数ぶん新 index がずれる。
  func testLegacyActiveTabMapsToFirstLeafOfOldActiveTab() throws {
    let tmp = try workspacesFile()
    let v3 = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/r","activeTab":1,"tabs":[\
      {"tree":{"split":{"vertical":true,"ratio":0.5,\
      "first":{"leaf":{"cwd":"/a"}},"second":{"leaf":{"cwd":"/b"}}}}},\
      {"tree":{"leaf":{"cwd":"/c"}}}]}]}
      """
    try Data(v3.utf8).write(to: tmp)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(loaded.workspaces[0].tabs.map(\.cwd), ["/a", "/b", "/c"])
    XCTAssertEqual(loaded.workspaces[0].activeTab, 2, "前の分割タブの 2 葉ぶんずれる")
  }

  /// 葉の cwd が無ければ workspace の rootPath へ落とす（0 タブ時の新タブ cwd と同じ fallback）。
  func testLegacyLeafWithoutCwdFallsBackToRootPath() throws {
    let tmp = try workspacesFile()
    let v3 = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/root","activeTab":0,"tabs":[{"tree":{"leaf":{}}}]}]}
      """
    try Data(v3.utf8).write(to: tmp)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(loaded.workspaces[0].tabs.map(\.cwd), ["/root"])
  }

  /// 旧形式の他フィールド（lastUsedAt・windowSize・activeWorkspace）はそのまま写す。
  func testLegacyFileKeepsOtherFields() throws {
    let tmp = try workspacesFile()
    let v3 = """
      {"version":3,"activeWorkspace":1,"windowSize":{"width":700,"height":400},"workspaces":[\
      {"name":"a","rootPath":"/a","activeTab":0,"tabs":[{"tree":{"leaf":{}}}],"lastUsedAt":123},\
      {"name":"b","rootPath":"/b","activeTab":0,"tabs":[]}]}
      """
    try Data(v3.utf8).write(to: tmp)
    let loaded = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(loaded.activeWorkspace, 1)
    XCTAssertEqual(loaded.windowSize, WindowSize(width: 700, height: 400))
    XCTAssertEqual(loaded.workspaces[0].lastUsedAt, Date(timeIntervalSinceReferenceDate: 123))
    XCTAssertEqual(loaded.workspaces[1].tabs, [], "0 タブの休眠 workspace はそのまま")
  }
}
