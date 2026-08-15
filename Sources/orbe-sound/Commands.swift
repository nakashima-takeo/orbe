import Foundation
import OrbeSound

// orbe-sound のサブコマンド実装と引数ヘルパ。流儀は orbe-cli と同じ手書き switch ディスパッチ
// （終了コード 0 = 成功 / 2 = usage エラー / 1 = 実行エラー、余った引数は黙って捨てず usage エラー）。

let usage = """
  orbe-sound — 通知音の制作ループ CLI（オフライン合成・dev 専用）

  USAGE:
    orbe-sound list
    orbe-sound render <name> <done|waiting|-> [--out <path>] [--rate <hz>] [--volume <5-100>]
    orbe-sound play <name> <done|waiting|-> [--rate <hz>] [--volume <5-100>]
    orbe-sound analyze <name> <done|waiting|-> [--rate <hz>] [--volume <5-100>]
    orbe-sound analyze --all [--rate <hz>] [--volume <5-100>]
    orbe-sound board [--out <dir>] [--rate <hz>] [--volume <5-100>]

  <name> はカタログ 12 案の名前か scratch のエントリ名（list で確認）。カタログは
  <done|waiting> を、scratch はイベント区別が無いので "-" を渡す。
  既定: --rate 48000 / --volume 90。render は --out 省略時、一時ディレクトリへ書く。
  analyze --all はカタログ全 24 音 + scratch の peak / RMS / loud 一覧（ラウドネス整合の目視は loud）。
  board は全音の WAV + 自己完結の index.html を書き、そのパスを出す（人間の聴き比べ用。
  クリック再生と A/B 比較。--out 省略時は毎回同じ場所に上書き＝ブラウザのリロードで最新）。

  制作ループ: Sources/orbe-sound/Scratch.swift を編集 →
    swift build --product orbe-sound && .build/debug/orbe-sound board
  を回し、開きっぱなしのブラウザをリロードして聴く（1 音だけ耳で確かめるなら play でもよい）。
  ビルドは manifest 解決に GhosttyKit（vendor/ghostty）の実在が要る。worktree の vendor は
  build-app.sh がビルド中だけ main worktree へ symlink し、終了時に空へ戻す（symlink を残すと
  git status が壊れるため。→ docs/guides/build.md）。制作ループは main checkout で回すこと。

  Exit codes: 0 success, 2 usage error, 1 実行エラー（書き込み・再生失敗等）。
  """

// MARK: - 出力・終了・引数ヘルパ

func stderrLine(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// usage エラー（引数不正）。終了コード 2。戻り道を必ず添える——サブコマンド別の help は
/// 無いので、これが無いと `render --help` が「何が書けるのか」を出さずに死ぬ。
func usageDie(_ message: String) -> Never {
  stderrLine("error: \(message)")
  stderrLine("run: orbe-sound --help")
  exit(2)
}

/// 実行エラー（書き込み・再生失敗等）。終了コード 1。
func die(_ message: String) -> Never {
  stderrLine("error: \(message)")
  exit(1)
}

/// 値必須オプションを抜き取る（残りを inout で縮める）。フラグ自体が無ければ nil。
/// 空文字・空白だけの値は席を空けたのと同じ——通すと `--out ""` がカレントディレクトリに化け、
/// board が指定と違う場所へ 28 ファイル撒いて成功終了する。
func takeOption(_ args: inout [String], _ name: String, requires label: String) -> String? {
  guard let i = args.firstIndex(of: name) else { return nil }
  guard i + 1 < args.count, !args[i + 1].hasPrefix("-"),
    !args[i + 1].trimmingCharacters(in: .whitespaces).isEmpty
  else {
    usageDie("\(name) requires \(label)")
  }
  let value = args[i + 1]
  args.removeSubrange(i...(i + 1))
  return value
}

/// `--rate` を抜き取って検証する。render/play/analyze 単体・analyze --all・board の 3 経路が
/// **必ずこれを通る**（検証も既定値も経路ごとに写すと写し忘れで割れる）。下限 8000 は可聴品質の底、
/// 上限 768000（8×96 kHz）は Double→Int 変換の域外の値（inf・1e300 等）を合成層へ届かせて
/// シグナル死させないための入口の守り。
func takeRate(_ args: inout [String]) -> Double {
  guard let token = takeOption(&args, "--rate", requires: "a sample rate in hz") else {
    return 48000
  }
  guard let value = Double(token), (8000...768000).contains(value) else {
    usageDie("invalid rate: \(token)")
  }
  return value
}

/// `--volume` を抜き取って検証する（5-100。takeRate と同じく全経路共通）。
/// 既定 90 はアプリの既定音量（`SettingsRegistry` の `sound.volume`）に合わせてある。
func takeVolume(_ args: inout [String]) -> Int {
  guard let token = takeOption(&args, "--volume", requires: "a volume (5-100)") else { return 90 }
  guard let value = Int(token), (5...100).contains(value) else {
    usageDie("invalid volume: \(token)")
  }
  return value
}

/// フラグを取り切った後の残余を検査する。席に座れなかったトークンは usage エラー
/// ——黙って捨てると、指定と違う音を聴いて判断を誤る。位置引数は `parseTarget` が先に食うので、
/// ここへ来る時点で席は残っていない。
func rejectLeftovers(_ args: [String]) {
  if let flag = args.first(where: { $0.hasPrefix("-") && $0 != "-" }) {
    usageDie("unknown option: \(flag)")
  }
  if let first = args.first {
    usageDie("unexpected argument: \(first)")
  }
}

// MARK: - 対象の解決

/// 解決済みの合成対象。カタログ（案 × イベント）と scratch エントリを同じ形に落とす。
struct ResolvedSound {
  let name: String
  let program: SoundProgram
  /// ノイズの決定論シードの素。カタログはアプリと同じ key にして、同じ波形が鳴るようにする。
  let seedKey: String
}

/// `<name> <done|waiting|->` を解決する。カタログ名は scratch より優先する
/// （scratch にカタログと同名のエントリを作っても届かないので、名前を変えること）。
func resolve(name: String, eventToken: String) -> ResolvedSound {
  if let family = NotificationSound(rawValue: name) {
    guard let event = AgentSoundEvent(rawValue: eventToken) else {
      usageDie("catalog sound '\(name)' needs <done|waiting>")
    }
    let key = "\(name)/\(eventToken)"
    return ResolvedSound(
      name: key, program: SoundCatalog.program(family, event), seedKey: key)
  }
  if let entry = Scratch.entries.first(where: { $0.name == name }) {
    guard eventToken == "-" else {
      usageDie("scratch sound '\(name)' has no events — pass \"-\"")
    }
    return ResolvedSound(name: name, program: entry.program, seedKey: name)
  }
  usageDie("unknown sound: \(name)  (see: orbe-sound list)")
}

/// render / play / analyze が共有する解決済みの合成指定。
struct Target {
  let sound: ResolvedSound
  let rate: Double
  let volume: Int
}

/// render / play / analyze が共有する位置引数 + 共通フラグの取り出し。
func parseTarget(_ args: inout [String]) -> Target {
  let rate = takeRate(&args)
  let volume = takeVolume(&args)
  guard args.count >= 2 else { usageDie("expected <name> <done|waiting|->") }
  let sound = resolve(name: args[0], eventToken: args[1])
  args.removeSubrange(0...1)
  return Target(sound: sound, rate: rate, volume: volume)
}

// MARK: - サブコマンド

func runList(_ args: [String]) {
  rejectLeftovers(args)
  print("catalog (<name> done|waiting):")
  for family in NotificationSound.allCases { print("  \(family.rawValue)") }
  print("scratch (<name> -):")
  for entry in Scratch.entries { print("  \(entry.name)") }
}

/// render の本体（play と共用）。WAV を書いてパスを返す。
func renderWAV(_ sound: ResolvedSound, rate: Double, volume: Int, out: String?) -> URL {
  let samples = SoundRenderer.render(
    program: sound.program, volume: volume, sampleRate: rate, seedKey: sound.seedKey)
  let url =
    out.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-sound-\(sound.name.replacingOccurrences(of: "/", with: "-")).wav")
  do {
    try WAVWriter.write(samples: samples, sampleRate: rate, to: url)
  } catch {
    die("cannot write \(url.path): \(error.localizedDescription)")
  }
  return url
}

func runRender(_ rawArgs: [String]) {
  var args = rawArgs
  let out = takeOption(&args, "--out", requires: "a file path")
  let target = parseTarget(&args)
  rejectLeftovers(args)
  let url = renderWAV(target.sound, rate: target.rate, volume: target.volume, out: out)
  print(
    "\(target.sound.name)  \(String(format: "%.2f", target.sound.program.duration))s  \(url.path)")
}

func runPlay(_ rawArgs: [String]) {
  var args = rawArgs
  let target = parseTarget(&args)
  rejectLeftovers(args)
  let url = renderWAV(target.sound, rate: target.rate, volume: target.volume, out: nil)
  let afplay = Process()
  afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
  afplay.arguments = [url.path]
  do {
    try afplay.run()
  } catch {
    die("cannot run afplay: \(error.localizedDescription)")
  }
  afplay.waitUntilExit()
  if afplay.terminationStatus != 0 { die("afplay failed (\(afplay.terminationStatus))") }
}

/// 一覧の 1 行（--all とカタログ単体で共用）。
private func analysisRow(name: String, samples: [Float], rate: Double) -> String {
  let result = SoundAnalysis.analyze(samples, sampleRate: rate)
  let padded = name + String(repeating: " ", count: max(0, 16 - name.count))
  return padded
    + String(
      format: " %6.2fs  peak %7.2f dB  rms %7.2f dB  loud %7.2f dB  crest %6.2f dB",
      result.duration, result.peakDB, result.rmsDB, result.maxShortTermRMSDB, result.crestDB)
}

func runAnalyze(_ rawArgs: [String]) {
  var args = rawArgs
  if let allIndex = args.firstIndex(of: "--all") {
    args.remove(at: allIndex)
    let rate = takeRate(&args)
    let volume = takeVolume(&args)
    rejectLeftovers(args)
    for family in NotificationSound.allCases {
      for event in AgentSoundEvent.allCases {
        let samples = SoundRenderer.render(
          family: family, event: event, volume: volume, sampleRate: rate)
        print(
          analysisRow(name: "\(family.rawValue)/\(event.rawValue)", samples: samples, rate: rate))
      }
    }
    for entry in Scratch.entries {
      let samples = SoundRenderer.render(
        program: entry.program, volume: volume, sampleRate: rate, seedKey: entry.name)
      print(analysisRow(name: entry.name, samples: samples, rate: rate))
    }
    return
  }

  let target = parseTarget(&args)
  rejectLeftovers(args)
  let samples = SoundRenderer.render(
    program: target.sound.program, volume: target.volume, sampleRate: target.rate,
    seedKey: target.sound.seedKey)
  print(analysisRow(name: target.sound.name, samples: samples, rate: target.rate))
  let peaks = SoundAnalysis.spectralPeaks(samples, sampleRate: target.rate, count: 5)
  if !peaks.isEmpty {
    print("spectral peaks:")
    for peak in peaks {
      print(String(format: "  %8.1f Hz  %7.2f dB", peak.frequency, peak.levelDB))
    }
  }
}
