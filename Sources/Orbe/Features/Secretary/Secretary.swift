import Foundation

/// 秘書の係が窓に頼むこと。
protocol SecretaryHost: AnyObject {
  /// 検出済みの claude。
  var secretaryClaude: AgentCLI? { get }
  /// 各 CLI へ登録した同梱プラグインの名前（自動化のスキルを名指しするため）。同梱の無い起動では nil。
  var secretaryPluginName: String? { get }
  /// Home に新しいタブで `command` を起こし、開いている画面を閉じて Home へ切り替え、そのタブを選ぶ。起こせなければ false。
  func secretaryOpen(command: String) -> Bool
}

/// 頼みの出どころ。起こした claude の役目の指示を決める。
enum SecretaryOrigin {
  /// ⌘⇧X の入力の行き先。
  case palette
  /// Home のボード（依頼の欄）。
  case board
}

/// 秘書の係（窓に 1 つ。状態を持たない）。頼みのたびに、出どころの役目の指示と頼みの本文を起動の引数にして、Home で
/// claude を 1 つ起こす。
final class Secretary {
  /// 頼みを受けられない理由。
  enum Refusal: Error, Equatable {
    case claudeMissing
    /// 本文が空（打った文が空白・制御文字だけ）。
    case empty
    /// Home にタブを起こせない。
    case unavailable
  }

  private weak var host: SecretaryHost?
  private let localization: LocalizationStore

  init(host: SecretaryHost, localization: LocalizationStore) {
    self.host = host
    self.localization = localization
  }

  func ask(_ ask: String, from origin: SecretaryOrigin) throws(Refusal) {
    guard let input = SecretaryText.firstInput(ask, l10n: localization) else {
      throw .empty
    }
    guard let host, let claude = host.secretaryClaude else { throw .claudeMissing }
    let command = AgentCatalog.startCommand(
      claude,
      arguments: [
        "--append-system-prompt",
        SecretaryText.instructions(
          for: origin, localization.language, pluginName: host.secretaryPluginName),
      ],
      firstInput: input)
    guard host.secretaryOpen(command: command) else { throw .unavailable }
  }
}
