import Foundation
import OrbeSound

// orbe-sound board — 聴き比べ用のブラウザフロントエンド。全音（カタログ 24 + scratch）を WAV に
// 書き出し、自己完結の index.html（外部リソースなし・CSS/JS インライン）を同じディレクトリへ生成する。
// 制作ループの人間側はこのボードが担う: 生成 → ブラウザで開く → 以降はリロードだけで最新になる。

/// board の 1 エントリ（生成時に解析値を埋め込む）。
struct BoardEntry {
  let section: String  // "catalog" / "scratch"
  let name: String  // 表示名（glass/done, demo-signal）
  let file: String  // WAV ファイル名
  let duration: Double
  let rmsDB: Double
}

func runBoard(_ rawArgs: [String]) {
  var args = rawArgs
  let out = takeOption(&args, "--out", requires: "a directory path")
  let rate = takeOption(&args, "--rate", requires: "a sample rate in hz").map { token -> Double in
    guard let value = Double(token), value >= 8000 else { usageDie("invalid rate: \(token)") }
    return value
  }
  let volume = takeOption(&args, "--volume", requires: "a volume (5-100)").map { token -> Int in
    guard let value = Int(token), (5...100).contains(value) else {
      usageDie("invalid volume: \(token)")
    }
    return value
  }
  rejectLeftovers(args, positionals: 0)

  // --out 省略時は毎回同じ既定ディレクトリへ上書きする——ブラウザはリロードだけで最新になる。
  let dir =
    out.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-sound-board", isDirectory: true)
  do {
    let index = try generateBoard(to: dir, rate: rate ?? 48000, volume: volume ?? 70)
    print(index.path)
  } catch {
    die("cannot write board: \(error.localizedDescription)")
  }
}

/// board の生成本体（テストから直接呼ぶ）。WAV 群と index.html を書き、index.html の URL を返す。
func generateBoard(to dir: URL, rate: Double, volume: Int) throws -> URL {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

  var entries: [BoardEntry] = []
  for family in NotificationSound.allCases {
    for event in AgentSoundEvent.allCases {
      let samples = SoundRenderer.render(
        family: family, event: event, volume: volume, sampleRate: rate)
      let file = "\(family.rawValue)-\(event.rawValue).wav"
      try WAVWriter.write(samples: samples, sampleRate: rate, to: dir.appendingPathComponent(file))
      entries.append(
        BoardEntry(
          section: "catalog", name: "\(family.rawValue)/\(event.rawValue)", file: file,
          duration: Double(samples.count) / rate, rmsDB: SoundAnalysis.rmsDB(samples)))
    }
  }
  for entry in Scratch.entries {
    let samples = SoundRenderer.render(
      program: entry.program, volume: volume, sampleRate: rate, seedKey: entry.name)
    let file = "\(entry.name).wav"
    try WAVWriter.write(samples: samples, sampleRate: rate, to: dir.appendingPathComponent(file))
    entries.append(
      BoardEntry(
        section: "scratch", name: entry.name, file: file,
        duration: Double(samples.count) / rate, rmsDB: SoundAnalysis.rmsDB(samples)))
  }

  let index = dir.appendingPathComponent("index.html")
  try boardHTML(entries: entries, rate: rate, volume: volume)
    .write(to: index, atomically: true, encoding: .utf8)
  return index
}

private func cardHTML(_ entry: BoardEntry) -> String {
  let stats = String(format: "%.2f s · RMS %.1f dB", entry.duration, entry.rmsDB)
  return """
        <div class="card" tabindex="0" data-src="\(entry.file)" data-name="\(entry.name)">
          <div class="name">\(entry.name)</div>
          <div class="stats">\(stats)</div>
          <div class="ab"><button data-slot="a">A</button><button data-slot="b">B</button></div>
        </div>
    """
}

private func sectionHTML(_ title: String, _ entries: [BoardEntry]) -> String {
  """
    <section>
      <h2>\(title)</h2>
      <div class="grid">
    \(entries.map(cardHTML).joined(separator: "\n"))
      </div>
    </section>
  """
}

// swiftlint:disable function_body_length
private func boardHTML(entries: [BoardEntry], rate: Double, volume: Int) -> String {
  let catalog = entries.filter { $0.section == "catalog" }
  let scratch = entries.filter { $0.section == "scratch" }
  return """
    <!doctype html>
    <html lang="ja">
    <head>
    <meta charset="utf-8">
    <title>orbe-sound board</title>
    <style>
      body { margin: 0; padding: 20px 24px 48px; background: #16161e; color: #c8c8d8;
             font: 14px/1.5 -apple-system, "Hiragino Sans", sans-serif; }
      h1 { font-size: 18px; margin: 0 0 4px; color: #e8e8f2; }
      h2 { font-size: 13px; margin: 24px 0 8px; color: #8a8aa0;
           text-transform: uppercase; letter-spacing: 0.08em; }
      .meta { color: #6a6a80; font-size: 12px; margin: 0 0 2px; }
      .help { color: #8a8aa0; font-size: 12px; margin: 0; }
      .help kbd { background: #24243a; border-radius: 4px; padding: 0 5px; color: #c8c8d8; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
              gap: 8px; }
      .card { background: #1e1e2c; border: 1px solid #2c2c40; border-radius: 8px;
              padding: 10px 12px; cursor: pointer; position: relative; user-select: none; }
      .card:hover { border-color: #46466a; }
      .card.playing { border-color: #7aa2f7; box-shadow: 0 0 0 1px #7aa2f7; }
      .card.slot-a::before, .card.slot-b::after {
        position: absolute; top: -7px; font-size: 11px; font-weight: 700;
        padding: 0 6px; border-radius: 6px; color: #16161e; }
      .card.slot-a::before { content: "A"; right: 34px; background: #9ece6a; }
      .card.slot-b::after { content: "B"; right: 8px; background: #e0af68; }
      .name { color: #e8e8f2; font-weight: 600; }
      .stats { color: #6a6a80; font-size: 12px; margin-top: 2px; }
      .ab { position: absolute; right: 8px; bottom: 8px; display: flex; gap: 4px;
            opacity: 0; transition: opacity 0.1s; }
      .card:hover .ab { opacity: 1; }
      .ab button { background: #2c2c40; color: #c8c8d8; border: none; border-radius: 4px;
                   width: 22px; height: 20px; font-size: 11px; cursor: pointer; }
      .ab button:hover { background: #46466a; }
      #slots { margin-top: 8px; font-size: 12px; color: #8a8aa0; }
      #slots b { color: #9ece6a; font-weight: 600; }
      #slots b + b { color: #e0af68; }
    </style>
    </head>
    <body>
    <header>
      <h1>orbe-sound board</h1>
      <p class="meta">rate \(Int(rate)) Hz · volume \(volume)%</p>
      <p class="help">クリックで再生。カード右下の A / B で割り当て →
        <kbd>a</kbd> <kbd>b</kbd> で即再生、<kbd>space</kbd> で交互（A/B 比較）。</p>
      <div id="slots">A: <b id="slot-a">—</b> &nbsp; B: <b id="slot-b">—</b></div>
    </header>
    \(sectionHTML("catalog", catalog))
    \(sectionHTML("scratch", scratch))
    <script>
    "use strict";
    const audio = new Audio();
    let playingCard = null;
    const slots = { a: null, b: null };
    let lastSlot = "b";  // space の初回は A から鳴る

    function play(card) {
      if (!card) return;
      audio.pause();
      audio.src = card.dataset.src;
      audio.currentTime = 0;
      audio.play();
      if (playingCard) playingCard.classList.remove("playing");
      playingCard = card;
      card.classList.add("playing");
    }
    audio.addEventListener("ended", () => {
      if (playingCard) playingCard.classList.remove("playing");
      playingCard = null;
    });

    function assign(slot, card) {
      if (slots[slot]) slots[slot].classList.remove("slot-" + slot);
      slots[slot] = card;
      card.classList.add("slot-" + slot);
      document.getElementById("slot-" + slot).textContent = card.dataset.name;
    }

    document.querySelectorAll(".card").forEach((card) => {
      card.addEventListener("click", (e) => {
        if (e.target.tagName === "BUTTON") return;
        play(card);
      });
      card.querySelectorAll(".ab button").forEach((btn) => {
        btn.addEventListener("click", () => assign(btn.dataset.slot, card));
      });
    });

    document.addEventListener("keydown", (e) => {
      if (e.key === "a") { lastSlot = "a"; play(slots.a); }
      else if (e.key === "b") { lastSlot = "b"; play(slots.b); }
      else if (e.key === " ") {
        e.preventDefault();
        lastSlot = lastSlot === "a" ? "b" : "a";
        play(slots[lastSlot]);
      }
    });
    </script>
    </body>
    </html>
    """
}
// swiftlint:enable function_body_length
