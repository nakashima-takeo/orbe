import XCTest

@testable import Orbe

/// 会話ごとのタブの索引が、同じ会話を持つタブが複数あるとき、生きているタブを休眠のタブより優先すること。
///
/// 壊れると何が起きるか: 人が手で再開した会話と休眠のタブが並ぶとき、続きからと秘書の係が休眠のタブを起こし、同じ会話が
/// 2 つの agent で進む。
final class AgentSessionTabsTests: OrbeTestCase {
  private func entry(_ tabId: Int, dormant: Bool) -> AgentSessionTabs.Entry {
    AgentSessionTabs.Entry(
      sessionId: "s-1", tab: AgentSessionTabs.Tab(tabId: tabId, title: "t\(tabId)"),
      isDormant: dormant)
  }

  func testALiveTabWinsOverADormantTabOfTheSameConversationInEitherOrder() {
    let index = AgentSessionTabs()

    index.update([entry(1, dormant: true), entry(2, dormant: false)])
    XCTAssertEqual(index.tabs["s-1"]?.tabId, 2)

    index.update([entry(2, dormant: false), entry(1, dormant: true)])
    XCTAssertEqual(index.tabs["s-1"]?.tabId, 2)

    index.update([entry(1, dormant: true), entry(3, dormant: true)])
    XCTAssertEqual(index.tabs["s-1"]?.tabId, 1, "どれも休眠なら先に来た方")
  }
}
