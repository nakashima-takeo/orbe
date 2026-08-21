import AppKit
import XCTest

@testable import Orbe

/// workspace 永続のロジック検証（libghostty 非依存）。
/// 分割ツリーの直列化/復元は TerminalController を window 未接続で操作すれば
/// surface を起こさずトポロジー＋cwd＋比率だけ検証できる。
final class WorkspacePersistenceTests: OrbeTestCase {

  /// テストの復元では resume を起こさない（agent 付き葉のトポロジー検証のみ）。
  private let noResume: TerminalController.ResumeSpawn = { _ in nil }

  // MARK: - スキーマ Codable 往復

  func testSchemaCodableRoundTrip() throws {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 1,
      workspaces: [
        WorkspaceState(
          name: "default", rootPath: "/Users/x", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: "/a", agent: nil), explicitTitle: nil)]),
        WorkspaceState(
          name: "api", rootPath: "/srv", activeTab: 0,
          tabs: [
            TabState(
              tree: .split(
                vertical: true, ratio: 0.3,
                first: .leaf(cwd: "/b", agent: nil),
                second: .split(
                  vertical: false, ratio: 0.7,
                  first: .leaf(cwd: "/c", agent: nil),
                  second: .leaf(cwd: nil, agent: nil))),
              explicitTitle: "tree")
          ]),
      ])
    let data = try JSONEncoder().encode(file)
    let back = try JSONDecoder().decode(WorkspacesFile.self, from: data)
    XCTAssertEqual(back, file, "Codable 往復で構成が一致（入れ子分割・nil cwd 含む）")
  }

  func testVersionMismatchIsRejectedOnLoad() throws {
    let tmp = try workspacesFile()
    let future = WorkspacesFile(
      version: 999, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "a", rootPath: "/", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)])
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
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)])
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
          tabs: [TabState(tree: .leaf(cwd: "/Users/me/a", agent: nil), explicitTitle: "ed")]),
        WorkspaceState(
          name: "api", rootPath: "/srv/api", activeTab: 1,
          tabs: [
            TabState(tree: .leaf(cwd: "/srv/api", agent: nil), explicitTitle: nil),
            TabState(
              tree: .split(
                vertical: true, ratio: 0.35,
                first: .leaf(cwd: "/srv/api/x", agent: nil),
                second: .leaf(cwd: "/srv/api/y", agent: nil)),
              explicitTitle: nil),
          ]),
      ])
    WorkspacePersistence.save(original)

    XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "save で実ファイルが生成される")
    let reloaded = WorkspacePersistence.load()
    XCTAssertEqual(
      reloaded, original,
      "ディスク経由で名前・rootPath・activeTab・分割ツリー・比率・cwd・activeWorkspace が一致")
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
              tree: .leaf(
                cwd: "/p",
                agent: AgentSession(command: "claude", sessionId: "27d05777-57b4-4baa-9532-bc4cac")),
              explicitTitle: nil),
            TabState(tree: .leaf(cwd: "/q", agent: nil), explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "agent セッション(command+sessionId)と agent 無し葉の混在がディスク往復で保たれる")
  }

  // MARK: - 分割ツリーの直列化

  func testSnapshotOfSplitTree() {
    let tc = TerminalController()
    XCTAssertEqual(tc.snapshot(), .leaf(cwd: nil, agent: nil), "初期は葉1つ・cwd 未報告は nil")

    tc.split(.horizontal)  // 左右分割（縦線）= vertical:true
    guard case .split(let vertical, _, let first, let second) = tc.snapshot() else {
      return XCTFail("分割後は split ノード")
    }
    XCTAssertTrue(vertical, "左右分割は vertical:true")
    XCTAssertEqual(first, .leaf(cwd: nil, agent: nil))
    XCTAssertEqual(second, .leaf(cwd: nil, agent: nil))
  }

  // MARK: - 復元単位（TabState）の組み立て

  /// 復元単位（tabState）は tree だけでなく明示タイトルも載せる——起動時復元と
  /// ⇧⌘T が共有する契約なので、どちらか 1 つ落ちると片方だけ静かに壊れる。
  func testTabStateCarriesTreeAndTitle() {
    let node: PaneNode = .split(
      vertical: true, ratio: 0.4,
      first: .leaf(cwd: "/work/api", agent: nil), second: .leaf(cwd: "/work/web", agent: nil))
    let tc = TerminalController(restoring: node, resumeSpawn: noResume)
    tc.explicitTitle = "api"
    XCTAssertEqual(
      tc.tabState(), TabState(tree: node, explicitTitle: "api"),
      "tabState は分割ツリーと明示タイトルを一括で載せる")
  }

  // MARK: - 復元の往復（PaneNode → 再構築 → 再 snapshot）

  func testRestoreRoundTripPreservesTreeCwdAndRatio() {
    let node: PaneNode = .split(
      vertical: true, ratio: 0.4,
      first: .leaf(cwd: "/work/api", agent: nil),
      second: .leaf(cwd: "/work/web", agent: nil))
    let tc = TerminalController(restoring: node, resumeSpawn: noResume)
    XCTAssertEqual(tc.snapshot(), node, "復元ツリーは構造・cwd・比率を保って再 snapshot できる")
  }

  func testRestoreSinglePaneCwd() {
    let node: PaneNode = .leaf(cwd: "/home/me/project", agent: nil)
    let tc = TerminalController(restoring: node, resumeSpawn: noResume)
    XCTAssertEqual(tc.snapshot(), node, "単一ペインの cwd が復元値として保たれる")
  }

  // MARK: - エージェントセッションの復元

  /// agent 付き葉は消費（materialize 開始）時に resumeSpawn へ解決を依頼し、起動指示を確定する。
  /// snapshot は休眠中も消費後も agent セッションを保つ（再起動往復が冪等）。
  func testRestoreAgentLeafResolvesResumeAndPreservesAgent() {
    var captured: AgentSession?
    let node: PaneNode = .leaf(
      cwd: "/w", agent: AgentSession(command: "claude", sessionId: "abc-123"))
    let tc = TerminalController(
      restoring: node,
      resumeSpawn: { session in
        captured = session
        return ("claude --resume abc-123", ["PATH": "/usr/bin"])
      })
    XCTAssertNil(captured, "resume 解決は復元時ではなく消費時")
    XCTAssertEqual(tc.snapshot(), node, "休眠のままの snapshot も agent セッションを保つ")

    tc.recordMaterializationStarted()
    XCTAssertEqual(
      captured, AgentSession(command: "claude", sessionId: "abc-123"),
      "消費時に resumeSpawn へ解決を依頼する")
    let pane = tc.controlAllPanes()[0]
    XCTAssertEqual(pane.initialCommand, "claude --resume abc-123", "解決した起動指示が spawn に効く")
    XCTAssertEqual(pane.initialEnv, ["PATH": "/usr/bin"])
    XCTAssertEqual(tc.snapshot(), node, "消費後の snapshot も agent セッションを保つ（冪等）")
  }

  /// resume を解決できなければ消費時に素のシェルへ落ち、以後の snapshot に agent は付かない。
  /// セッション記録そのものは休眠のあいだ保持される（resume 可否は消費まで判定しない）。
  func testRestoreAgentLeafFallsBackToShellWhenUnresolved() {
    let node: PaneNode = .leaf(
      cwd: "/w", agent: AgentSession(command: "unknown", sessionId: "x"))
    let tc = TerminalController(restoring: node, resumeSpawn: noResume)
    XCTAssertEqual(tc.snapshot(), node, "休眠のあいだセッション記録は保持される")

    tc.recordMaterializationStarted()
    let pane = tc.controlAllPanes()[0]
    XCTAssertEqual(pane.agentSlot, .none, "解決不可なら消費で素のシェルへ落ちる")
    XCTAssertNil(pane.initialCommand)
    XCTAssertEqual(
      tc.snapshot(), .leaf(cwd: "/w", agent: nil), "素シェル化後の snapshot に agent は付かない")
  }

  /// agent が command だけ（sessionId キー欠落）の永続ファイルも読め、sessionId は nil になる。
  /// decode を厳格化すると `load()` が全体 nil に倒れ、ユーザーの workspace 構成が既定で潰され
  /// 原本が quarantine される——欠落キーは常に緩和方向（エラーではなく nil）で受ける。
  func testAgentWithoutSessionIdKeyLoadsAsNilIdentity() throws {
    let tmp = try workspacesFile()
    let json = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/r","activeTab":0,"tabs":[\
      {"tree":{"leaf":{"cwd":"/r/a","agent":{"command":"claude"}}}}]}]}
      """
    try Data(json.utf8).write(to: tmp)

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "sessionId キー欠落で全構成を失わない")
    XCTAssertEqual(
      loaded.workspaces[0].tabs[0].tree,
      .leaf(cwd: "/r/a", agent: AgentSession(command: "claude", sessionId: nil)),
      "欠落キーは nil として読む（CLI 名の記録は残る）")
    XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "原本を quarantine へ退避しない")
  }

  /// sessionId を持たない同一性は、休眠でも稼働中でも snapshot に書かない。resume 不能な記録を
  /// ディスクへ増やすと、次の起動で必ず素シェル化する死にチケットが永続し、⇧⌘T のゲートも
  /// 誤って通り始める。
  func testSnapshotDropsIdentitiesWithoutASessionId() {
    let dormant = TerminalController(
      restoring: .leaf(cwd: "/w", agent: AgentSession(command: "claude", sessionId: nil)),
      resumeSpawn: noResume)
    XCTAssertEqual(
      dormant.snapshot(), .leaf(cwd: "/w", agent: nil), "sessionId 欠落のチケットは保存しない")

    let live = TerminalController()
    setReportedState(live.focusedPane!, "working", command: "claude")
    XCTAssertEqual(
      live.focusedPane?.agentSlot.session, AgentSession(command: "claude", sessionId: nil),
      "前提: 報告が sessionId を運ぶ前の稼働")
    XCTAssertEqual(
      live.snapshot(), .leaf(cwd: nil, agent: nil), "同一性が未確定の稼働も保存しない")
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
            TabState(tree: .leaf(cwd: "/p", agent: nil), explicitTitle: "build"),
            TabState(tree: .leaf(cwd: "/q", agent: nil), explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "明示タイトルあり/なしの混在がディスク往復で保たれる")
  }

  /// 旧 v2 JSON（version:2・タブ＝素の PaneNode）も load() が受理し（version ゲート緩和）、
  /// 既存タブ構成を失わず explicitTitle=nil で読む。起動を通した現行バージョンへの書き直しは
  /// `WindowControllerRestoreTests.testLaunchFromLegacyV2FileRewritesToCurrentVersion` が持つ。
  func testLegacyV2FileLoads() throws {
    let tmp = try workspacesFile()
    let v2 = """
      {"version":2,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/r","activeTab":0,"tabs":[{"leaf":{"cwd":"/r/a"}}]}]}
      """
    try Data(v2.utf8).write(to: tmp)

    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "v2 も load が受理する（ゲート緩和）")
    XCTAssertEqual(loaded.version, 2, "読み込み時点では v2 のまま")
    let tab = loaded.workspaces[0].tabs[0]
    XCTAssertNil(tab.explicitTitle, "旧 v2 タブは explicitTitle=nil")
    XCTAssertEqual(tab.tree, .leaf(cwd: "/r/a", agent: nil), "既存タブ構成（cwd）を失わない")
  }

  /// 旧形式 JSON（tabs が素の PaneNode＝explicitTitle キー無し）も decode でき、
  /// explicitTitle は nil・tree は正しく復元される（既存タブ構成を失わない・version は 2 据え置き）。
  func testLegacyTabsWithoutExplicitTitleDecode() throws {
    let legacy = """
      {"version":2,"activeWorkspace":0,"workspaces":[\
      {"name":"default","rootPath":"/","activeTab":0,"tabs":[\
      {"split":{"vertical":true,"ratio":0.4,\
      "first":{"leaf":{"cwd":"/a"}},"second":{"leaf":{"cwd":"/b"}}}}]}]}
      """
    let file = try JSONDecoder().decode(WorkspacesFile.self, from: Data(legacy.utf8))
    let tab = file.workspaces[0].tabs[0]
    XCTAssertNil(tab.explicitTitle, "旧形式は explicitTitle=nil として読む")
    XCTAssertEqual(
      tab.tree,
      .split(
        vertical: true, ratio: 0.4,
        first: .leaf(cwd: "/a", agent: nil), second: .leaf(cwd: "/b", agent: nil)),
      "旧形式（素の PaneNode）の分割ツリーが失われず復元される")
  }
}
