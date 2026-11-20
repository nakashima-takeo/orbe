import Foundation

@testable import Orbe

/// workspace で走るコマンドのノード。「PR の確認」は自動化の workspace が orbe で、取得 `prs` が継ぎ、副作用 `sync` は自分の
/// workspace（dotfiles）、副作用 `archive` は消した workspace を書いている。「旧リポジトリの掃除」は自動化の workspace を消して
/// いて、継ぐ `clean` の最新の回は workspace が見つからずに失敗した。
extension DesignSceneFixtures {
  static let orbeWorkspace = AutomationWorkspace(
    id: UUID(uuidString: "6F1E0C2A-0000-4000-8000-000000000003")!, name: "orbe",
    root: "/Users/me/src/orbe")
  static let dotfilesWorkspace = AutomationWorkspace(
    id: UUID(uuidString: "6F1E0C2A-0000-4000-8000-000000000004")!,
    name: "dotfiles", root: "/Users/me/dotfiles")
  /// どの workspace にも無い（消した）workspace。
  static let removedWorkspace = UUID(uuidString: "6F1E0C2A-0000-4000-8000-000000000009")!

  /// Home・orbe・dotfiles。
  static var boardWorkspaces: AutomationWorkspaces {
    let home = AutomationWorkspace(
      id: UUID(uuidString: "6F1E0C2A-0000-4000-8000-000000000001")!,
      name: "Home", root: "/Users/me/Library/Application Support/Orbe/home")
    return AutomationWorkspaces(all: [home, orbeWorkspace, dotfilesWorkspace], home: home.id)
  }

  static func boardWorkspaceSamples() -> [AutomationSample] {
    let prs = AutomationSample(
      definition: AutomationDefinition(
        name: "PR の確認", notify: nil, workspace: orbeWorkspace.id,
        nodes: [
          commandNode(
            "prs", "自分の PR", .scheduled(.every(3600)),
            script: "gh pr list --author @me --json url,title,updatedAt", directory: ".",
            coverage: .currentSet),
          commandNode(
            "sync", "設定の同期", .manual, from: ["prs"], script: "./sync.sh",
            workspace: dotfilesWorkspace.id, directory: "bin", deliver: .sideEffect),
          commandNode(
            "archive", "記録の保存", .manual, from: ["prs"], script: "./archive.sh",
            workspace: removedWorkspace, directory: "tools", deliver: .sideEffect),
        ]),
      createdAt: automationAt(9, daysAgo: 2),
      passes: [
        AutomationSamplePass(
          nodeKey: "prs", at: automationAt(14, 30),
          outcome: fetched(sampleItems("prs", 3, at: automationAt(14, 30))))
      ])
    let clean = AutomationSample(
      definition: AutomationDefinition(
        name: "旧リポジトリの掃除", notify: nil, workspace: removedWorkspace,
        nodes: [
          commandNode(
            "clean", "ブランチの掃除", .scheduled(cron("0 9 * * 1")),
            script: "git fetch --prune", directory: ".", deliver: .sideEffect)
        ]),
      createdAt: automationAt(9, daysAgo: 9),
      passes: [
        AutomationSamplePass(
          nodeKey: "clean", at: automationAt(9, daysAgo: 4),
          outcome: failed("", ending: .workspaceMissing))
      ])
    return [prs, clean]
  }
}
