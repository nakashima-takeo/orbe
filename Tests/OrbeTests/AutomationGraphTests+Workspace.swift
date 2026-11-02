import XCTest

@testable import Orbe

/// 走る workspace の導きと、作業ディレクトリ・自動化の workspace の規則。走る workspace はコマンドのノードだけが持ち、ノードの
/// workspace か、無ければ自動化の workspace。workspace が効くコマンドの作業ディレクトリは root からの相対パスで必ず書き、効かない
/// コマンドは絶対パスか省略。
///
/// 壊れると何が起きるか: 自動化の workspace を書き足したのに絶対パスのノードが黙って別の場所で走る。workspace を消した後の書き戻しで
/// 相対パスの定義がホームで走る。agent が workspace の中で走る。効く先の無い自動化の workspace が残り、候補の付け先と取り違え
/// られる。自動化の workspace を替えても継ぐノードの回が止まらず、古い場所の結果が新しい定義の結果として確定する。
extension AutomationGraphTests {
  private static let repo = UUID()
  private static let tools = UUID()

  private static func command(
    _ key: String, workspace: UUID? = nil, directory: String?, from inputs: [String] = []
  ) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(
      key, key, .manual, from: inputs, script: "run \(key)", workspace: workspace,
      directory: directory, deliver: .sideEffect)
  }

  private func refusal(_ definitionNodes: [AutomationDefinition.Node], workspace: UUID?) -> String? {
    do {
      _ = try AutomationGraph.check(definitionNodes, workspace: workspace)
      return nil
    } catch {
      guard case .invalid(let message) = error else { return "\(error)" }
      return message
    }
  }

  func testTheDirectoryFollowsWhetherAWorkspaceApplies() {
    let needed =
      "nodes[0].directory: a node that runs in a workspace needs a directory relative to its root "
      + #"("." for the root)"#
    XCTAssertEqual(
      refusal([Self.command("a", workspace: Self.repo, directory: nil)], workspace: nil), needed,
      "ノードの workspace")
    XCTAssertEqual(
      refusal([Self.command("a", directory: nil)], workspace: Self.repo), needed, "継いだ workspace")
    XCTAssertEqual(
      refusal([Self.command("a", directory: "/src/orbe")], workspace: Self.repo),
      "nodes[0].directory: write the directory relative to the workspace root")
    XCTAssertEqual(
      refusal([Self.command("a", directory: ".")], workspace: nil),
      "nodes[0].directory: a relative directory needs a workspace (the node's or the automation's)")
    XCTAssertEqual(
      refusal(
        [DesignSceneFixtures.commandNode("a", "a", .manual, script: " ", deliver: .sideEffect)],
        workspace: nil),
      "nodes[0].command: command is empty")
    XCTAssertNil(refusal([Self.command("a", directory: "/src/orbe")], workspace: nil))
    XCTAssertNil(refusal([Self.command("a", directory: nil)], workspace: nil), "ホーム")
    XCTAssertNil(refusal([Self.command("a", directory: "../up")], workspace: Self.repo))
  }

  /// 自動化の workspace は、それを継ぐコマンドのノードがあるときだけ書ける。
  func testTheAutomationWorkspaceNeedsACommandNodeThatInheritsIt() {
    let message =
      "workspace: no command node runs in it; write it only when a command node without its own "
      + "workspace uses it"
    XCTAssertEqual(refusal([Self.agent("r")], workspace: Self.repo), message, "agent だけ")
    XCTAssertEqual(
      refusal([Self.command("a", workspace: Self.tools, directory: ".")], workspace: Self.repo),
      message, "どのコマンドも自分の workspace を書いた")
    XCTAssertNil(
      refusal(
        [Self.command("a", workspace: Self.tools, directory: "."), Self.command("b", directory: ".")],
        workspace: Self.repo))
  }

  func testTheNodeRunsInItsOwnWorkspaceOrElseTheAutomations() throws {
    let checked = try AutomationGraph.check(
      [
        Self.command("own", workspace: Self.tools, directory: "."),
        Self.command("inherits", directory: "sub"), Self.agent("r"),
      ], workspace: Self.repo)

    XCTAssertEqual(checked.map(\.workspace), [Self.tools, Self.repo, nil], "agent は workspace を持たない")
  }

  /// 何をするかに入るのは走る workspace——自動化の workspace を替えると継ぐノードだけが変わり、継いだのと同じ workspace を
  /// 書き足しても変わらない。
  func testTheBehaviorCarriesTheWorkspaceTheNodeRunsIn() throws {
    func behaviors(_ definitionNodes: [AutomationDefinition.Node], _ workspace: UUID?) throws
      -> [AutomationGraph.Behavior]
    {
      let checked = try AutomationGraph.check(definitionNodes, workspace: workspace)
      return AutomationGraph(
        checked,
        entities: checked.enumerated().map { index, item in
          AutomationNode(
            item.definitionNode, id: AutomationNodeID(index + 1),
            defId: AutomationNodeDefID(index + 1))
        }, workspace: workspace
      ).nodes.map(\.behavior)
    }
    let own = Self.command("own", workspace: Self.tools, directory: ".")
    let inherits = Self.command("inherits", directory: ".")

    let before = try behaviors([own, inherits], Self.repo)
    let moved = try behaviors([own, inherits], Self.tools)
    let written = try behaviors(
      [own, Self.command("inherits", workspace: Self.repo, directory: ".")], nil)

    XCTAssertEqual(before[0], moved[0], "自分の workspace を書いたノードは変わらない")
    XCTAssertNotEqual(before[1], moved[1], "継ぐノードは走る場所が変わる")
    XCTAssertEqual(before[1], written[1], "継いだのと同じ workspace を書いても変わらない")
  }
}
