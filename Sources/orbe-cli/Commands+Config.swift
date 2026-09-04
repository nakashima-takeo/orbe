import Foundation

// `orb config <サブコマンド>` の実装と usage。`runConfig` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

// MARK: - usage

/// `SettingsRegistry.all` の全 key。usage は socket 不達でも出す必要があるため config_list からは
/// 引けず、ここに写す。この一覧のドリフトは `testConfigHelpListsEveryRegistryKey` が
/// `config --help` の `KEYS:` 行と registry を突き合わせて落とす。`configSetUsage` の型内訳だけは
/// 手書きのままなので、registry に key を足したらそちらも足すこと。
let allConfigKeys = [
  "font-size", "background-opacity", "background-blur", "cursor-style-blink", "theme",
  "font-family", "tab-title-font-family", "emoji-font", "default-agent", "agent-state-icons",
  "worktree-dir", "notification-sound", "notification-sound-volume",
  "notification-sound-enabled", "notification-sound-custom-done",
  "notification-sound-custom-waiting", "notification-sound-custom-waiting-same-as-done",
  "menubar-notification-duration",
]

let configUsageLines = [
  "orb config list [--workspace [<id>]] [--json]",
  "orb config get <key> [--workspace [<id>]] [--json]",
  "orb config set <key> <value> [--workspace [<id>]]",
  "orb config unset <key> [--workspace [<id>]]",
]

let configUsage = """
  orb config — read and set Orbe settings

  USAGE:
  \(usageBlock(configUsageLines))

  KEYS: \(allConfigKeys.joined(separator: ", "))
  --workspace targets a workspace: <id> (or current) for a specific one, bare
  --workspace for the active one. Without the flag, config set/unset writes global.
  All settings are workspace-overridable; unset clears an override (back to inherit).
  """

let configSetUsage = """
  orb config set <key> <value> [--workspace [<id>]]

  KEYS: \(allConfigKeys.joined(separator: ", "))
    font-size, background-opacity, notification-sound-volume,
    menubar-notification-duration   integer
    background-blur, cursor-style-blink, notification-sound-enabled,
    notification-sound-custom-waiting-same-as-done   true/false/on/off/1/0
    theme (auto/light/dark), font-family, tab-title-font-family, emoji-font,
    default-agent, worktree-dir, notification-sound (a sound name or custom)   string
    agent-state-icons, notification-sound-custom-done,
    notification-sound-custom-waiting   map (set them from the settings palette)
  --workspace <id> writes that workspace's override, bare --workspace the active
  one (default without the flag: global).
  """

// MARK: - サブコマンド

func runConfig(_ args: [String]) -> Never {
  // --help はサブコマンドが自分の usage を出す（config set --help → configSetUsage）。ここで握らない。
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": configList(rest)
  case "get": configGet(rest)
  case "set": configSet(rest)
  case "unset": configUnset(rest)
  case nil:
    print(configUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(configUsage)
      exit(0)
    }
    usageDie("unknown config command: \(other)")
  }
}

private func configList(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(configUsage)
    exit(0)
  }
  var args = rest
  let target = takeWorkspaceTarget(&args, positionals: 0)
  rejectLeftovers(args, positionals: 0)
  var params: [String: Any] = [:]
  if case .id(let n) = target { params["workspaceId"] = n }
  let result = callOrExit("config_list", params)
  if wantJSON {
    printJSON(result)
  } else {
    let settings = (result as? [String: Any])?["settings"] as? [[String: Any]] ?? []
    for row in settings {
      let key = row["key"] as? String ?? "?"
      let value = display(row["value"] ?? NSNull())
      let scope = row["scope"] as? String ?? "?"
      print("\(key) = \(value) [\(scope)]")
    }
  }
  exit(0)
}

private func configGet(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(configUsage)
    exit(0)
  }
  var args = rest
  let target = takeWorkspaceTarget(&args, positionals: 1)
  rejectLeftovers(args, positionals: 1, dashOK: 1)
  guard let key = args.first, !key.hasPrefix("-") else { usageDie("config get requires <key>") }
  var params: [String: Any] = [:]
  if case .id(let n) = target { params["workspaceId"] = n }
  let row = configRowOrDie(key, params)
  if wantJSON { printJSON(row) } else { print(display(row["value"] ?? NSNull())) }
  exit(0)
}

private func configSet(_ args: [String]) -> Never {
  if hasHelp(args) {
    print(configSetUsage)
    exit(0)
  }
  var rest = args
  let target = takeWorkspaceTarget(&rest, positionals: 2)
  rejectLeftovers(rest, positionals: 2, dashOK: 2)
  guard rest.count >= 2, !rest[0].hasPrefix("-") else {
    usageDie("config set requires <key> <value>")
  }
  let key = rest[0]
  // key の妥当性・値型は control の config_list を SSOT に引く（CLI 側で二重管理しない）。
  let row = configRowOrDie(key)
  let value = typedConfigValue(type: row["type"] as? String, key: key, raw: rest[1])
  // .none→global；.active/.id→workspace（.id は対象 WS も送る）。
  var params: [String: Any] = ["key": key, "value": value]
  let scope: String
  switch target {
  case .none: scope = "global"
  case .active: scope = "workspace"
  case .id(let n):
    scope = "workspace"
    params["workspaceId"] = n
  }
  params["scope"] = scope
  let result = callOrExit("config_set", params)
  if wantJSON {
    printJSON(result)
  } else {
    print("ok: \(key) = \(display(value)) [\(scope)]")
  }
  exit(0)
}

/// 設定 1 項目の上書きを解除して継承へ戻す（wire は `config_set` の `value: null`）。global スコープでは
/// global 明示値を除去する。`--workspace` でその WS の上書きを解除する。
private func configUnset(_ args: [String]) -> Never {
  if hasHelp(args) {
    print(configUsage)
    exit(0)
  }
  var rest = args
  let target = takeWorkspaceTarget(&rest, positionals: 1)
  rejectLeftovers(rest, positionals: 1, dashOK: 1)
  guard let key = rest.first, !key.hasPrefix("-") else { usageDie("config unset requires <key>") }
  // key の妥当性は get / set と同じ口で引き、打ち間違いを同じ usage エラー（2）で弾く。
  _ = configRowOrDie(key)
  var params: [String: Any] = ["key": key, "value": NSNull()]
  let scope: String
  switch target {
  case .none: scope = "global"
  case .active: scope = "workspace"
  case .id(let n):
    scope = "workspace"
    params["workspaceId"] = n
  }
  params["scope"] = scope
  let result = callOrExit("config_set", params)
  if wantJSON {
    printJSON(result)
  } else {
    print("unset: \(key) [\(scope)]")
  }
  exit(0)
}

/// control の config_list が返す type（int/bool/enum）で wire 値型を決める。パース失敗は usage エラー。
private func typedConfigValue(type: String?, key: String, raw: String) -> Any {
  switch type {
  case "int":
    guard let n = Int(raw) else { usageDie("\(key) expects an integer, got: \(raw)") }
    return n
  case "bool":
    guard let b = parseBool(raw) else {
      usageDie("\(key) expects true/false/on/off/1/0, got: \(raw)")
    }
    return b
  default:  // enum（theme / font-family / default-agent）は文字列
    return raw
  }
}
