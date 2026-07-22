import XCTest

@testable import Orbe

/// FileTree（`ls-files` のパス列 → ツリー構築）のテスト。
final class GitTreeTests: XCTestCase {

  func testFoldersFirstThenNameOrder() {
    let nodes = FileTree.build(paths: [
      "Package.swift",
      ".orbe.json",
      "src/agent/StateHooks.swift",
      "src/agent/EmitBuffer.swift",
      "docs/README.md",
      "src/renderer/Renderer.swift",
    ])
    // 第1階層: フォルダ（docs, src）→ ファイル（.orbe.json, Package.swift）。
    XCTAssertEqual(nodes.map(\.name), ["docs", "src", ".orbe.json", "Package.swift"])
    XCTAssertEqual(nodes.map(\.isDirectory), [true, true, false, false])

    let src = nodes[1]
    XCTAssertEqual(src.path, "src")
    XCTAssertEqual(src.children?.map(\.name), ["agent", "renderer"])

    let agent = src.children![0]
    XCTAssertEqual(agent.path, "src/agent")
    XCTAssertEqual(agent.children?.map(\.name), ["EmitBuffer.swift", "StateHooks.swift"])
    XCTAssertEqual(agent.children?.map(\.path).first, "src/agent/EmitBuffer.swift")
    XCTAssertEqual(agent.children?.map(\.isDirectory), [false, false])
  }

  func testCaseInsensitiveOrderIsStable() {
    let nodes = FileTree.build(paths: ["b.txt", "A.txt", "a.txt"])
    XCTAssertEqual(nodes.map(\.name), ["A.txt", "a.txt", "b.txt"])
  }

  func testEmptyInput() {
    XCTAssertEqual(FileTree.build(paths: []), [])
  }

  func testDuplicatePathsCollapse() {
    let nodes = FileTree.build(paths: ["docs/a.md", "docs/a.md"])
    XCTAssertEqual(nodes.count, 1)
    XCTAssertEqual(nodes[0].children?.count, 1)
  }
}
