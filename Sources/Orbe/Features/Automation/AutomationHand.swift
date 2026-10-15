import SwiftUI

/// 自動化 1 つへの人の手の操作（今すぐ実行・止める ⇄ 再開・削除）。キー・キーの表示・名前・断りをここだけが決め、⌘⇧X の
/// 中身とボードが使う——キーを変えたとき、片方の画面の表示だけが嘘になる写しを残さないため。
enum AutomationHand {
  enum Operation {
    case togglePause
    case runNow
    case delete

    var key: String {
      switch self {
      case .togglePause: "space"
      case .runNow: "↵"
      case .delete: "⌘⌫"
      }
    }

    /// 止める ⇄ 再開は、止めているかで名前が替わる。
    func title(paused: Bool) -> L10nKey {
      switch self {
      case .togglePause: paused ? .automationResume : .automationPause
      case .runNow: .automationRunNow
      case .delete: .automationDelete
      }
    }
  }

  /// キーが操作に当たった。押し続けたキーリピートは握るが何もしない（取り消せない操作を繰り返さない）。
  enum Stroke: Equatable {
    case press(Operation)
    case held
  }

  /// 断り。行き違い（消えていた等）は黙り、断るのは走っている間の今すぐ実行だけ。
  enum Refusal: Equatable {
    case running

    var message: L10nKey {
      switch self {
      case .running: .automationErrRunning
      }
    }
  }

  /// 修飾なしの ↵＝今すぐ実行、space＝止める ⇄ 再開、⌘⌫＝削除。他のキーは nil。
  static func stroke(_ press: KeyPress) -> Stroke? {
    let operation: Operation
    switch press.key {
    case .return where press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]):
      operation = .runNow
    case .space:
      operation = .togglePause
    case .backspace where press.modifiers.contains(.command):
      operation = .delete
    default:
      return nil
    }
    return press.phase == .down ? .press(operation) : .held
  }

  /// 走らせ役へ通す。
  static func perform(
    _ operation: Operation, on automation: Automation, runner: AutomationRunner
  ) -> Refusal? {
    switch operation {
    case .runNow:
      do throws(AutomationError) {
        try runner.runNow(automation.id)
      } catch {
        if case .running = error { return .running }
      }
    case .togglePause:
      _ = try? runner.pause(automation.id, !automation.paused)
    case .delete:
      try? runner.delete(automation.id)
    }
    return nil
  }
}
