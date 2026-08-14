import Foundation

// 通知音の制作ループ用 dev CLI（オフライン合成のみ）。動作中の Orbe には一切関与しない
// （orbe-cli の control.sock とは別物の独立ツール）。app には同梱しない。
// Scratch.swift を編集 → `swift build --product orbe-sound` → `orbe-sound play <name> -`
// が制作ループの本体。サブコマンドと引数の扱いは Commands.swift。

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
  print(usage)
  exit(2)
}
switch args[0] {
case "--help", "-h":
  print(usage)
  exit(0)
case "list":
  runList(Array(args.dropFirst()))
case "render":
  runRender(Array(args.dropFirst()))
case "play":
  runPlay(Array(args.dropFirst()))
case "analyze":
  runAnalyze(Array(args.dropFirst()))
default:
  usageDie("unknown command: \(args[0])")
}
