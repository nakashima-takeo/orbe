import AppKit
import XCTest

@testable import Orbe

/// 分割ツリー（host 所有の NSSplitView レイアウト）の不変条件を守る。
/// window に未接続なら SurfaceView は libghostty surface を生成しない
/// （生成は viewDidMoveToWindow 依存）ため、libghostty を起動せずトポロジーだけ検証できる。
///
/// 各ペインは SurfaceScrollView（ネイティブスクロールバー付き）でラップされてツリーに置かれる。
/// よって分割の arrangedSubview / rootContainer 直下の葉は SurfaceScrollView で、
/// その中の SurfaceView は `.surfaceView` で取り出す。
final class TerminalControllerTests: OrbeTestCase {
  /// 分割した拡張ファイル（+Agent）からも使うため internal。
  func rootSplit(_ tc: TerminalController) -> NSSplitView? {
    tc.rootContainer.subviews.first as? NSSplitView
  }

  /// 葉ラップ（SurfaceScrollView）から SurfaceView を取り出す。分割した拡張ファイルからも使う。
  func pane(_ v: NSView) -> SurfaceView {
    (v as! SurfaceScrollView).surfaceView
  }

  func testInitialSinglePane() {
    let tc = TerminalController()
    XCTAssertEqual(tc.rootContainer.subviews.count, 1)
    XCTAssertTrue(tc.rootContainer.subviews.first is SurfaceScrollView)
    XCTAssertNotNil(tc.focusedPane)
  }

  func testSplitOrientation() {
    let h = TerminalController()
    h.split(.horizontal)  // 左右分割 = 縦の境界線 → isVertical = true
    XCTAssertEqual(rootSplit(h)?.isVertical, true)
    XCTAssertEqual(rootSplit(h)?.arrangedSubviews.count, 2)

    let v = TerminalController()
    v.split(.vertical)  // 上下分割 = 横の境界線 → isVertical = false
    XCTAssertEqual(rootSplit(v)?.isVertical, false)
    XCTAssertEqual(rootSplit(v)?.arrangedSubviews.count, 2)
  }

  func testNestedSplitOnFocusedPane() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    tc.split(.horizontal)  // root: split1[a, b]
    let split1 = rootSplit(tc)!
    let b = pane(split1.arrangedSubviews[1])

    tc.focusedPaneChanged(b)  // フォーカスを b へ移す
    tc.split(.vertical)  // b を分割 → split1: [a, split2[b, c]]

    XCTAssertTrue(pane(split1.arrangedSubviews[0]) === a)
    let split2 = split1.arrangedSubviews[1] as? NSSplitView
    XCTAssertNotNil(split2)
    XCTAssertEqual(split2?.arrangedSubviews.count, 2)
    XCTAssertTrue(pane(split2!.arrangedSubviews[0]) === b)
  }

  func testClosePaneCollapsesSplitAndPromotesSibling() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])

    tc.close(b, origin: .gesture)  // 残り 1 枚 → split を畳んで a を rootContainer 直下へ昇格

    XCTAssertEqual(tc.rootContainer.subviews.count, 1)
    XCTAssertTrue(pane(tc.rootContainer.subviews.first!) === a)
  }

  /// 最後の 1 枚を閉じたら onEmpty が発火し、**発火源を判断せずそのまま素通しする**。
  /// 全ケースを回すのは、素通しがどれか 1 つへの決め打ちに化けるのを止めるため——化けても
  /// コンパイルは通り、「⌘W で閉じたタブが戻らない」か「shell exit まで積む」が静かに起きる。
  func testCloseLastPaneFiresOnEmptyCarryingOrigin() {
    for origin in [TabCloseOrigin.gesture, .process, .controlAPI] {
      let tc = TerminalController()
      let exp = expectation(description: "onEmpty fires for \(origin)")
      var received: TabCloseOrigin?
      tc.onEmpty = {
        received = $0
        exp.fulfill()
      }
      tc.close(tc.focusedPane!, origin: origin)  // ルート唯一のペイン → このタブを閉じる通知（main へ async）
      wait(for: [exp], timeout: 1.0)
      XCTAssertEqual(received, origin, "close の発火源をそのまま上位へ渡す")
    }
  }

  /// ⌘W（`.closePane`）は人のジェスチャとして届く。キーから close までの唯一の分岐点で、
  /// ここが `.process` に化けると ⇧⌘T が主用途（⌘W で閉じた直後）で無反応になる。
  func testClosePaneChromeActionReportsGestureOrigin() {
    let tc = TerminalController()
    let exp = expectation(description: "onEmpty fires")
    var received: TabCloseOrigin?
    tc.onEmpty = {
      received = $0
      exp.fulfill()
    }
    tc.focusedPane!.perform(.closePane)  // ⌘W の届き先（Keybindings → SurfaceView.perform）
    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(received, .gesture, "⌘W は人のジェスチャとして届く")
  }

  func testPreferredFocusPaneFollowsLastFocus() {
    let tc = TerminalController()
    let a = tc.focusedPane!
    XCTAssertTrue(tc.preferredFocusPane === a, "初期は最初のペイン")

    tc.split(.horizontal)
    let b = pane(rootSplit(tc)!.arrangedSubviews[1])
    tc.focusedPaneChanged(b)
    XCTAssertTrue(tc.preferredFocusPane === b, "最後にフォーカスしたペインを返す")
  }

  func testRequestWindowCommandForwardsToHandler() {
    let tc = TerminalController()
    var received: [TerminalController.WindowCommand] = []
    tc.onWindowCommand = { received.append($0) }
    tc.requestWindowCommand(.newTab)
    tc.requestWindowCommand(.switchWorkspace)
    XCTAssertEqual(received, [.newTab, .switchWorkspace])
  }

  func testPanePwdChangedFiresOnPwdChange() {
    let tc = TerminalController()
    var fired = 0
    tc.onPwdChange = { fired += 1 }
    tc.panePwdChanged()
    XCTAssertEqual(fired, 1)
  }

  func testPaneAgentStateChangedFiresOnAgentStateChange() {
    let tc = TerminalController()
    var fired = 0
    tc.onAgentStateChange = { fired += 1 }
    tc.paneAgentStateChanged()
    XCTAssertEqual(fired, 1)
  }

  // MARK: - displayTitle の precedence（① explicitTitle ?? ② paneTitle ?? ③ derived）

  func testDisplayTitleExplicitWins() {
    let tc = TerminalController()
    tc.focusedPane!.paneTitle = "vim"
    tc.focusedPane!.initialCwd = "/Users/me/proj/src"
    tc.explicitTitle = "build"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "build", "① explicitTitle が最優先")
  }

  func testDisplayTitleFallsBackToPaneTitle() {
    let tc = TerminalController()
    tc.focusedPane!.paneTitle = "vim"
    tc.focusedPane!.initialCwd = "/Users/me/proj/src"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "vim", "明示なし → ② paneTitle(非空)")
  }

  func testDisplayTitleFallsBackToDerivedWhenPaneTitleEmpty() {
    let tc = TerminalController()
    tc.focusedPane!.initialCwd = "/Users/me/proj/src/app"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "p/s/app",
      "明示なし・paneTitle 空 → ③ derived（圧縮アンカーは root の親＝先頭に root 名）")
  }

  func testDisplayTitleEmptyExplicitFallsThrough() {
    let tc = TerminalController()
    tc.focusedPane!.paneTitle = "vim"
    tc.explicitTitle = ""  // 空は採用しない（②③へ戻る）
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: nil), "vim", "空の explicitTitle は無視し ② へ")
  }

  func testDisplayTitleIgnoresPwdFallbackTitle() {
    // libghostty は明示タイトル未受信の間、生 pwd を paneTitle に入れる（OSC 7 フォールバック）。
    // paneTitle == currentPwd ならそれは pwd フォールバックなので②を飛ばし③で圧縮整形する。
    let tc = TerminalController()
    tc.focusedPane!.currentPwd = "/Users/me/proj/src/app"
    tc.focusedPane!.paneTitle = "/Users/me/proj/src/app"  // Ghostty の pwd フォールバックと同値
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "p/s/app",
      "paneTitle == currentPwd（pwd フォールバック）は ② にせず ③ で圧縮")
  }

  func testDisplayTitleKeepsAppTitleDifferingFromPwd() {
    // 本物のアプリタイトル（pwd と異なる）は②としてそのまま採用する。
    let tc = TerminalController()
    tc.focusedPane!.currentPwd = "/Users/me/proj/src/app"
    tc.focusedPane!.paneTitle = "vim"
    XCTAssertEqual(
      tc.displayTitle(workspaceRoot: "/Users/me/proj"), "vim",
      "paneTitle != currentPwd は本物のアプリタイトル → ②")
  }

  func testAggregatePicksWorkingOverDone() {
    let tc = TerminalController()
    tc.split(.horizontal)
    let split = rootSplit(tc)!
    let a = pane(split.arrangedSubviews[0])
    let b = pane(split.arrangedSubviews[1])
    setReportedState(a, "done")
    setReportedState(b, "working")
    // working(b) が done(a) に勝つ（CLI 非依存）
    XCTAssertEqual(tc.aggregateAgentState(), .working)
  }
}
