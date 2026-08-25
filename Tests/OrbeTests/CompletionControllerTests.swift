import AppKit
import XCTest

@testable import Orbe

/// popup facade（`CompletionController`）が engine の解析事実をどう配るかを検証する。
/// update は結果の照合トークンを一致品質へ、確定コマンド列を学習スコープへ渡し、host は
/// どちらも生バッファから導き直さない——その結線を、外から観察できる出力面
/// （選択中候補・`scopes`）だけで固定する。
/// 学習ストアには触らない（`CompletionLearning.shared` のメモリは空のままで、記録経路は
/// libghostty surface を要する accept 側にしか無い）＝ここは学習ゼロの並びを見る。
///
/// `scopes` の導出そのもの・`rank` の純ロジックは `CompletionLearningTests` が、
/// engine が何を載せるかは `CompletionEngineTests` が持つ。
@MainActor
final class CompletionControllerTests: OrbeTestCase {
  private func controller() -> CompletionController {
    CompletionController(translucency: ChromeTranslucency())
  }

  private func choice(_ value: String, type: String?) -> CompletionChoice {
    CompletionChoice(value: value, description: "", insertValue: nil, type: type)
  }

  func testUpdateRanksWithEngineMatchingToken() {
    // パス途中の結果。候補値は basename 化されていて、engine の照合トークンも同じ世界の値
    // （`main.swift`）。両者が同じ世界にある限り完全一致が接尾辞付きを追い越す。
    // トークン全域（`sub/main.swift`）を照合に回すと両候補の一致品質が潰れ、engine 元順の
    // `main.swift.orig` が選ばれたままになる。
    let controller = controller()
    let result = CompletionResult(
      choices: [choice("main.swift.orig", type: "file"), choice("main.swift", type: "file")],
      replaceLength: 14, query: "main.swift", commandPath: ["cat"])

    controller.update(
      buffer: "cat sub/main.swift", result: result, replaceStart: 4, replaceEnd: 18)

    XCTAssertEqual(controller.current?.value, "main.swift", "engine の照合トークンで完全一致が先頭に来る")
  }

  func testUpdateDerivesLearningScopesFromEngineCommandPath() {
    // accept（record）が読む値そのもの。engine の確定コマンド列から二層スコープを導き、
    // rank と record が同じ事実を共有する。
    // 打鍵（`npm i`）と確定コマンド列（`["npm","install"]`）がずれる入力を選ぶ——生バッファから
    // 導くと `npm i` にしかならないので、期待値の `npm install` は engine 由来でしか出ない。
    let controller = controller()
    XCTAssertEqual(
      controller.scopes, CompletionLearning.LearningScopes(staticScope: "", dynamicScope: ""),
      "update 前は何も分かっていない（前提）")

    controller.update(
      buffer: "npm i --sa",
      result: CompletionResult(
        choices: [choice("--save", type: "option")], replaceLength: 4, query: "--sa",
        commandPath: ["npm", "install"]),
      replaceStart: 6, replaceEnd: 10)

    XCTAssertEqual(
      controller.scopes,
      CompletionLearning.LearningScopes(staticScope: "npm install", dynamicScope: "npm"))
  }

  func testUpdateReplacesLearningScopesOnReuse() {
    // popup は使い回される（`SurfaceView` が既存 controller を再利用する）。別コマンドの結果が
    // 来たら前回のスコープは残らず、accept が古いコマンドの学習キーへ書かない。
    // 2 回目は引数の自由テキストを挟んだ位置——生バッファから導くと
    // `git commit -m "fix stuff"` になるので、期待値の `git commit` は engine 由来でしか出ない。
    let controller = controller()
    controller.update(
      buffer: "npm i --sa",
      result: CompletionResult(
        choices: [choice("--save", type: "option")], replaceLength: 4, query: "--sa",
        commandPath: ["npm", "install"]),
      replaceStart: 6, replaceEnd: 10)

    controller.update(
      buffer: "git commit -m \"fix stuff\" --am",
      result: CompletionResult(
        choices: [choice("--amend", type: "option")], replaceLength: 4, query: "--am",
        commandPath: ["git", "commit"]),
      replaceStart: 26, replaceEnd: 30)

    XCTAssertEqual(
      controller.scopes,
      CompletionLearning.LearningScopes(staticScope: "git commit", dynamicScope: "git"),
      "直近 update の確定コマンド列だけが残る")
  }
}
