#if DEBUG
  import Foundation

  /// gallery / flow の fixture が一時リポジトリで回す git。失敗すれば投げる（握り潰すと fixture の `isReady` の待ちが
  /// 原因を指さずに落ちる）。
  struct FixtureGit {
    struct Failure: Error {
      let arguments: [String]
      let stderr: String
    }

    let directory: URL

    func callAsFunction(_ arguments: [String]) throws {
      let output = GitRunner.shared.runSync(arguments, cwd: directory.path)
      guard output.isSuccess else {
        throw Failure(
          arguments: arguments, stderr: String(bytes: output.stderr, encoding: .utf8) ?? "")
      }
    }
  }
#endif
