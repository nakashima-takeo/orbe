import AppKit
import XCTest

@testable import Orbe

/// `prompt_agent` のドメイン側（`controlPromptAgent`）——どの状態のペインに届き、どの状態を拒むか
/// ——を実 `WindowController` で固定する。wire の二段 hop と応答の形は L3（`ControlWireTests+PromptAgent`）
/// が Fake で持ち、ここは Fake が見ない「ペインの状態と surface の有無」だけを見る。
///
/// 壊れると何が起きるか: `waiting`（permission ダイアログ / AskUserQuestion が開いている）へ
/// text＋Enter が届けば、既定選択の確定＝ツール実行の承認が「テキストを送る」動詞の副作用として起きる。
/// 未 mount のペインへ通せば、`controlSendText` が no-op のまま待機だけが張られ、時間切れまで黙る。
/// 逆に `idle` / `done` / 報告なしを拒めば、prompt はどこにも届かない動詞になる。
extension WindowControllerControlTests {
  /// 実効 state ごとの受け入れ。`working` / `waiting` だけが拒まれ、message は現在の state と
  /// `send_key` への導線を含む。
  func testPromptIsRefusedOnlyWhileTheAgentIsWorkingOrWaiting() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main")])
    let pane = try XCTUnwrap(wc.current.tabs.first?.controlAllPanes().first)
    XCTAssertNotNil(pane.surfacePtr, "前提: アクティブ WS のペインは mount 済み")

    for busy in ["working", "waiting"] {
      setReportedState(pane, busy)
      let refusal = wc.controlPromptAgent(pane: pane, text: "hello")
      XCTAssertEqual(refusal?.code, -32000, "\(busy) のエージェントへは送らない")
      XCTAssertEqual(
        refusal?.message, "agent busy (state: \(busy); answer a waiting agent with send_key)",
        "拒否の文言は現在の state と send_key への導線を含む")
    }

    for open in ["idle", "done"] {
      setReportedState(pane, open)
      XCTAssertNil(wc.controlPromptAgent(pane: pane, text: "hello"), "\(open) には送れる")
    }
    pane.agentSlot = .none
    XCTAssertNil(wc.controlPromptAgent(pane: pane, text: "hello"), "報告の無いペインにも送れる")
  }

  /// 未 mount（surface 無し）のペインは -32000 "pane not mounted"。休眠 workspace のペインがその形。
  func testPromptToAnUnmountedPaneIsRefused() throws {
    let wc = try restore(activeWorkspace: 0, [tabbed("main"), tabbed("dormant")])
    let pane = try XCTUnwrap(wc.workspaces.last?.tabs.first?.controlAllPanes().first)
    XCTAssertNil(pane.surfacePtr, "前提: 休眠 WS のペインは surface を持たない")

    let refusal = wc.controlPromptAgent(pane: pane, text: "hello")

    XCTAssertEqual(refusal?.code, -32000)
    XCTAssertEqual(refusal?.message, "pane not mounted")
  }
}
