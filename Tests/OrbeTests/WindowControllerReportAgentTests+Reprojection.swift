import XCTest

@testable import Orbe

/// `report_agent` が鳴らす chrome 再投影の配達経路（ファイル分割の拡張）。②ピルは一覧の投影なので、
/// 一覧から行が消えたら取り下げられ、ペイン集合が増えたら追随する。どちらも「操作が本番経路で
/// 再投影を要求したか」を測るもので、harness（`makeControllerAndPane` 等）は本体ファイルが持つ。
/// 立てる②の中身のうち滞留の尺——発信元 workspace の実効値から決まる——もここが測る。
extension WindowControllerReportAgentTests {

  // MARK: - ②ピルの取り下げ（一覧の投影であることの配達経路）
  //
  // 取り下げの印は `retracted`——ピル自体は収縮を描き切るまで残り、落とすのは閉じ切った
  // `MenuBarController`（②が消える見え方を収縮 1 つに保つ）。ここで測るのは「配達が届いて
  // 取り下げが決まるか」なので、見るのは印であって nil 化ではない。

  /// coalesce された行の再計算を同期で回す。**`refreshChrome` は呼ばない**——それは再投影を要求
  /// する側（本番の通知ハンドラ）の仕事で、テストが肩代わりすると「要求が届いたか」を測れなく
  /// なる。`flushChrome` は dirty が立っていなければ何もしないので、直前の操作が本番経路で
  /// `refreshChrome` を鳴らしていなければ取り下げは起きず、テストが落ちる。
  private func flushDelivered(_ wc: WindowController) {
    wc.flushChrome()
  }

  /// 同じペインが `working` へ戻ったらピルを取り下げる（`working` は一覧に載らない）。
  func testTransientWithdrawnWhenPaneReturnsToWorking() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    XCTAssertNotNil(wc.attentionStore.transient, "waiting のままなら取り下げない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  func testWaitingToIdleRetractsAttentionAndMovesTopBarWithoutNewNotification() throws {
    let (wc, pane) = try makeControllerAndPane()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    let played = sound.played.count

    wc.controlReportAgent(pane: pane, agent: "claude", state: "idle", sessionId: nil, message: nil)
    flushDelivered(wc)

    XCTAssertEqual(sound.played.count, played, "idle への変化で新しい音は鳴らさない")
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
    XCTAssertEqual(wc.statusModel.rollup.map(\.state), ["idle"])
    XCTAssertEqual(wc.statusModel.rollup.map(\.count), [1])
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  func testWaitingToUnknownRetractsEveryLiveProjectionWithoutNewNotification() throws {
    let (wc, pane) = try makeControllerAndPane()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    let played = sound.played.count

    wc.controlReportAgent(pane: pane, agent: "claude", state: "error", sessionId: nil, message: nil)
    flushDelivered(wc)

    XCTAssertEqual(sound.played.count, played)
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
    XCTAssertTrue(wc.statusModel.rollup.isEmpty)
    XCTAssertTrue(wc.statusModel.glyphs.allSatisfy { $0 == nil })
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  func testWaitingToClearRetractsEveryProjectionAndClearsState() throws {
    let (wc, pane) = try makeControllerAndPane()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    let played = sound.played.count

    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    flushDelivered(wc)

    XCTAssertEqual(sound.played.count, played)
    XCTAssertNil(pane.agentState)
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)
    XCTAssertTrue(wc.statusModel.rollup.isEmpty)
    XCTAssertTrue(wc.statusModel.glyphs.allSatisfy { $0 == nil })
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  /// done のフォーカス消費（done→idle）で行が消えたらピルを取り下げる。
  /// 消費そのものは通知を持たない（本番でも `wire` の onAgentStateChange が続けて
  /// `refreshChrome` を鳴らす）ので、その 1 手だけテスト側が同じ順で再現する。
  func testTransientWithdrawnWhenDoneConsumedToIdle() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d"))
    flushDelivered(wc)
    XCTAssertNotNil(wc.attentionStore.transient)

    wc.current.tabs[0].consumeDoneState()
    wc.refreshChrome()
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  /// ピルが指すペインのタブを閉じたら取り下げる。
  func testTransientWithdrawnWhenTabClosed() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.closeTab(wc.current.tabs[1], origin: .gesture)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  /// split の 1 枚だけを閉じても取り下げる。`close(_:)` → `onLayoutChange` → `refreshChrome`
  /// という配線が通っていなければ dirty が立たず `flushChrome` が空振りして落ちる。
  func testTransientWithdrawnWhenSplitPaneClosed() throws {
    let (wc, pane) = try makeControllerAndPane()
    let tab = wc.current.tabs[0]
    let sibling = try XCTUnwrap(tab.split(.horizontal, from: pane))

    wc.controlReportAgent(
      pane: sibling, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, sibling.id)

    tab.close(sibling, origin: .gesture)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.retracted, true)
  }

  /// 関係ない別ペインの状態変化では取り下げない（②を立て直さない変化だけで見る）。
  func testTransientSurvivesUnrelatedPaneChange() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "working", sessionId: nil, message: nil)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "clear", sessionId: nil, message: nil)
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.paneId, panes[1].id)
  }

  /// 同一ペインの waiting→done の差し替えは従来どおり働く（差し替え直後の flush で消えない）。
  func testTransientReplacementFromWaitingToDoneSurvivesFlush() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "waiting")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "done", sessionId: nil, message: AgentMessage(text: "d"))
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.transient?.row.state, "done")
  }

  /// 休眠（未 activate）workspace のペインでは②を立てない——通知を組む側（`agentNotification(for:)`）は
  /// 一覧（`AttentionSnapshot.rows`）と同じ activate 済み workspace のみを見る。立ててしまうと、
  /// その行は一覧に出ないので次の flush で即取り下げられる幽霊ピルになる。
  ///
  /// 到達性は低いが 0 ではない: 制御 API のペイン解決は休眠 workspace も走査するので、
  /// `report_agent` を直接撃てばここへ届く（hook 経由は休眠側に pty が無いので届かない）。
  func testTransientNotFiredForDormantWorkspacePane() throws {
    let (wc, dormantPane) = try makeControllerAndDormantPane()
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")

    wc.controlReportAgent(
      pane: dormantPane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    XCTAssertNil(wc.attentionStore.transient, "休眠 workspace のペインでは②を立てない")

    flushDelivered(wc)
    XCTAssertTrue(wc.attentionStore.rows.isEmpty, "一覧にも出ない（立てる側と同じ集合）")
  }

  // MARK: - ②の滞留（発信元 workspace の実効設定から到来時に決まる）

  /// 滞留は**発信元ペインが属する workspace** の実効値（`menubar-notification-duration`）で決まる。
  ///
  /// workspace を 2 つ立てて**アクティブでない方**から報告させる——1 つしか無いと発信元＝アクティブに
  /// なり、アクティブの実効設定を読む誤実装でも同じく緑になる（通知音の
  /// `testSoundReadsOriginWorkspaceOverride` と同じ問い）。
  func testTransientDwellReadsOriginWorkspaceOverride() throws {
    let (wc, panes) = try makeControllerAndTwoActivatedWorkspaces()
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.menuBarNotificationDuration, 20))
    var originOverride = SettingsLayer()
    originOverride[SettingKeys.menuBarNotificationDuration] = 120
    wc.workspaces[0].settingsOverride = originOverride
    var activeOverride = SettingsLayer()
    activeOverride[SettingKeys.menuBarNotificationDuration] = 60
    wc.workspaces[1].settingsOverride = activeOverride
    XCTAssertTrue(wc.current === wc.workspaces[1], "前提: アクティブは発信元でない方")

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))

    let transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(
      transient.expiresAt.timeIntervalSince(transient.arrivedAt), 120, accuracy: 0.001,
      "アクティブ側（60）でなく発信元 workspace の上書き（120）で滞留が決まる")
  }

  /// 上書きが無ければ global の実効値。何も設定しなければ既定の 40 秒。
  func testTransientDwellFallsBackToGlobalThenDefault() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil,
      message: AgentMessage(text: "q"))
    var transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(
      transient.expiresAt.timeIntervalSince(transient.arrivedAt), 40, accuracy: 0.001,
      "未設定の既定は 40 秒")

    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.menuBarNotificationDuration, 15))
    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: nil)
    transient = try XCTUnwrap(wc.attentionStore.transient)
    XCTAssertEqual(
      transient.expiresAt.timeIntervalSince(transient.arrivedAt), 15, accuracy: 0.001,
      "変更は次の到来から効く")
  }

  // MARK: - ペイン集合が増える側（split）の再投影

  /// split でも chrome 再投影を鳴らす。新ペインは状態を持たず単体では chrome 差分を作らないので、
  /// split の**後**に状態だけを直接立てて（通知は鳴らさない）一覧が追随するかで測る。
  /// `split()` の `onLayoutChange?()` が無ければ dirty が立たず `flushChrome` が空振りして落ちる。
  func testSplitReprojectsChrome() throws {
    let (wc, pane) = try makeControllerAndPane()
    wc.flushChrome()  // 起動時に積まれた再投影を消化し、dirty が立っていない地点から測る
    XCTAssertTrue(wc.attentionStore.rows.isEmpty)

    let sibling = try XCTUnwrap(wc.current.tabs[0].split(.horizontal, from: pane))
    setReportedState(sibling, "waiting")  // report 経路は通さない＝再投影を要求するのは split だけ
    flushDelivered(wc)
    XCTAssertEqual(wc.attentionStore.rows.map(\.paneId), [sibling.id])
  }
}
