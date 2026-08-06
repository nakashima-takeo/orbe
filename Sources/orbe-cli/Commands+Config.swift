import Foundation

// `orb <ドメイン> <サブコマンド>` の実装。ファイルはドメインごとに分け、各ドメインの `run*` が
// argv[2] を手書きでディスパッチする。各サブコマンドは -> Never で終端し、exit で終了コードを返す。

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
  rejectLeftoverFlags(args, positionals: 0)
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
  rejectLeftoverFlags(args, positionals: 1)
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
  rejectLeftoverFlags(rest, positionals: 2)
  guard rest.count >= 2 else { usageDie("config set requires <key> <value>") }
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
  rejectLeftoverFlags(rest, positionals: 1)
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
