import AppKit
import XCTest

@testable import Orbe

/// 開いている間に agent が結び付けた項目を、カードが取りに行く配線。
extension TaskPaletteCardKeyTests {
  private func link(_ kind: GitHubItemKind, _ number: Int) -> TaskLink {
    TaskPaletteSamples.link(kind, number)
  }

  private func linkedModel(githubItems: GitHubItemCache) -> TaskPaletteModel {
    TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "a") { $0.links = [self.link(.issue, 1), self.link(.pr, 2)] },
        TaskPaletteSamples.task(2, "b"),
      ], githubItems: githubItems)
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
