import AppKit
import XCTest

@testable import Orbe

/// 詳細の Issue・PR の欄の行に焦点があるときのキーと、開いている間に agent が結び付けた項目を
/// カードが取りに行く配線。
extension TaskPaletteCardKeyTests {
  private func link(_ kind: GitHubItemKind, _ number: Int) -> TaskLink {
    TaskPaletteSamples.link(kind, number)
  }

  private func linkedModel(githubItems: GitHubItemCache = GitHubItemCache(fetch: { _, _ in }))
    -> TaskPaletteModel
  {
    TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "a") { $0.links = [self.link(.issue, 1), self.link(.pr, 2)] },
        TaskPaletteSamples.task(2, "b"),
      ], githubItems: githubItems)
  }

  /// ↵ はその項目の GitHub のページを 1 回だけ開く。⌫ は押し続けても、押した 1 件だけを外す（焦点が
  /// 移った先の結び付きをリピートで外さない）。
  func testEnterOpensTheLinkOnceAndBackspaceUnlinksOnlyOneEvenWhenHeldDown() {
    let model = linkedModel()
    var opened: [URL] = []
    model.onOpenURL = { opened.append($0) }
    let window = mount(model)
    model.enterDetail()
    model.area = .detail(.link(link(.issue, 1).item))
    flush(window)

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    XCTAssertEqual(
      opened.map(\.absoluteString), ["https://github.com/o/n/issues/1"], "押し続けても開くのは 1 回だけ")

    press(Key.delete, "\u{7F}", to: window)
    press(Key.delete, "\u{7F}", repeating: true, to: window)
    press(Key.delete, "\u{7F}", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.first?.links, [link(.pr, 2)], "外れるのは押した 1 件だけ")
    XCTAssertEqual(model.area, .detail(.link(link(.pr, 2).item)))
  }

  /// 開いている間に agent が結び付けると、カードがその項目の値を取りに行く。
  func testAnItemTheAgentLinksWhileOpenIsFetched() throws {
    var requested: [Set<GitHubItemID>] = []
    let model = linkedModel(githubItems: GitHubItemCache { ids, _ in requested.append(Set(ids)) })
    _ = mount(model)

    var update = TaskUpdate()
    update.links = [link(.issue, 7)]
    _ = try model.store.update(2, update)
    pump(0.3)

    XCTAssertEqual(requested.last, [link(.issue, 7).item])
  }
}
