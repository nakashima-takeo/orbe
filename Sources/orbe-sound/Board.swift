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
  let loudDB: Double  // 最大短時間 RMS（dBFS）。ラウドネス整合の基準値
  let wavePoints: String  // 波形見取り図（SVG polygon の点列）
}

/// 波形見取り図の座標系。bucket 数の上限・SVG の viewBox・中心線・CSS の寸法はすべてここから出る。
/// **1 単位 = 1px に固定する**のが要点——`.wave` をカード幅に追従させると 1 単位の物理幅が
/// セクションごとに変わり、時間軸が board 全体で共通という性質がレンダリング時点で崩れる。
private enum WaveBox {
  /// 最長の音がちょうどこの幅になる（= bucket 数の上限）。
  static let width = 160
  static let height = 32
  /// 中心線。ポリゴンはここを軸に上下対称。
  static let mid = Double(height) / 2
  /// 中心線からの最大振幅——上下に 1 だけ余白を残す。
  static let amp = mid - 1
}

/// 波形の見取り図。|サンプル| を `buckets` 区間の最大値に間引き、中心線対称のポリゴン点列にする。
/// 時間軸は board 全体で共通——最長の音を全幅とし、各音は実時間比の幅だけ描く
/// （短い音が引き伸ばされて長く見えると、長さの比較がピンとこない）。
/// 高さは各音自身のピークで正規化する——図の仕事は音量でなく「形」（立ち上がり・リズム・余韻）を
/// 見せること。音量の比較は loud の数値が担う。
/// テストが直接叩くので internal（`generateBoard` と同じ扱い）。
func wavePoints(_ samples: [Float], buckets: Int) -> String {
  let mid = WaveBox.mid
  let amp = WaveBox.amp
  guard !samples.isEmpty, buckets > 0 else { return "" }
  var peaks = [Double](repeating: 0, count: buckets)
  for bucket in 0..<buckets {
    let lo = bucket * samples.count / buckets
    let hi = max(lo + 1, (bucket + 1) * samples.count / buckets)
    for i in lo..<hi { peaks[bucket] = max(peaks[bucket], Double(abs(samples[i]))) }
  }
  let peak = peaks.max() ?? 0
  let scale = peak > 0 ? amp / peak : 0
  let top = peaks.enumerated()
    .map { String(format: "%d,%.1f", $0.offset, mid - $0.element * scale) }
  let bottom = peaks.enumerated().reversed()
    .map { String(format: "%d,%.1f", $0.offset, mid + $0.element * scale) }
  return (top + bottom).joined(separator: " ")
}

func runBoard(_ rawArgs: [String]) {
  var args = rawArgs
  let out = takeOption(&args, "--out", requires: "a directory path")
  let rate = takeRate(&args)
  let volume = takeVolume(&args)
  rejectLeftovers(args)

  // --out 省略時は毎回同じ既定ディレクトリへ上書きする——ブラウザはリロードだけで最新になる。
  let dir =
    out.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbe-sound-board", isDirectory: true)
  do {
    let index = try generateBoard(to: dir, rate: rate, volume: volume)
    print(index.path)
  } catch {
    die("cannot write board: \(error.localizedDescription)")
  }
}

/// board の生成本体（テストから直接呼ぶ）。WAV 群と index.html を書き、index.html の URL を返す。
func generateBoard(to dir: URL, rate: Double, volume: Int) throws -> URL {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

  // 波形の時間軸を全音で揃えるため、まず全音を描画して最長サンプル数を知ってから entry を組む。
  struct Rendered {
    let section: String
    let name: String
    let file: String
    let samples: [Float]
  }
  var rendered: [Rendered] = []
  for family in NotificationSound.allCases {
    for event in AgentSoundEvent.allCases {
      let samples = SoundRenderer.render(
        family: family, event: event, volume: volume, sampleRate: rate)
      let file = "\(family.rawValue)-\(event.rawValue).wav"
      try WAVWriter.write(samples: samples, sampleRate: rate, to: dir.appendingPathComponent(file))
      rendered.append(
        Rendered(
          section: "catalog", name: "\(family.rawValue)/\(event.rawValue)", file: file,
          samples: samples))
    }
  }
  for entry in Scratch.entries {
    let samples = SoundRenderer.render(
      program: entry.program, volume: volume, sampleRate: rate, seedKey: entry.name)
    let file = "\(entry.name).wav"
    try WAVWriter.write(samples: samples, sampleRate: rate, to: dir.appendingPathComponent(file))
    rendered.append(Rendered(section: "scratch", name: entry.name, file: file, samples: samples))
  }
  let maxCount = rendered.map(\.samples.count).max() ?? 1
  let entries = rendered.map { item in
    BoardEntry(
      section: item.section, name: item.name, file: item.file,
      duration: Double(item.samples.count) / rate,
      loudDB: SoundAnalysis.maxShortTermRMSDB(item.samples, sampleRate: rate),
      wavePoints: wavePoints(
        item.samples, buckets: max(2, WaveBox.width * item.samples.count / maxCount)))
  }

  let index = dir.appendingPathComponent("index.html")
  try boardHTML(entries: entries, rate: rate, volume: volume)
    .write(to: index, atomically: true, encoding: .utf8)
  return index
}

private func cardHTML(_ entry: BoardEntry, showName: Bool = true) -> String {
  let stats = String(format: "%.2f s · loud %.1f dB", entry.duration, entry.loudDB)
  let name = showName ? "\n          <div class=\"name\">\(entry.name)</div>" : ""
  return """
        <div class="card" tabindex="0" data-src="\(entry.file)" data-name="\(entry.name)">\(name)
          <svg class="wave" viewBox="0 0 \(WaveBox.width) \(WaveBox.height)">
            <line x1="0" y1="\(WaveBox.mid)" x2="\(WaveBox.width)" y2="\(WaveBox.mid)"/>
            <polygon points="\(entry.wavePoints)"/></svg>
          <div class="stats">\(stats)</div>
          <div class="ab"><button data-slot="a">A</button><button data-slot="b">B</button></div>
        </div>
    """
}

/// カタログの面。1 行 = 1 案で、done / waiting を左右に並べる——縦の視線が案同士の比較、
/// 横の視線がその案のペア（同じ音色の 2 つの音形）になる。
private func pairedSectionHTML(_ title: String, _ entries: [BoardEntry]) -> String {
  var rows: [String] = []
  for pair in stride(from: 0, to: entries.count - 1, by: 2) {
    let family = entries[pair].name.split(separator: "/").first.map(String.init) ?? ""
    rows.append(
      """
          <div class="fname">\(family)</div>
      \(cardHTML(entries[pair], showName: false))
      \(cardHTML(entries[pair + 1], showName: false))
      """)
  }
  return """
      <section>
        <h2>\(title)</h2>
        <div class="pairs">
          <div></div><div class="colhead">done</div><div class="colhead">waiting</div>
      \(rows.joined(separator: "\n"))
        </div>
      </section>
    """
}

private func sectionHTML(_ title: String, _ entries: [BoardEntry]) -> String {
  """
    <section>
      <h2>\(title)</h2>
      <div class="grid">
    \(entries.map { cardHTML($0) }.joined(separator: "\n"))
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
      section { max-width: 760px; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
              gap: 8px; }
      .pairs { display: grid; grid-template-columns: 76px 1fr 1fr; gap: 8px;
               align-items: stretch; }
      .colhead { color: #6a6a80; font-size: 12px; text-transform: uppercase;
                 letter-spacing: 0.08em; }
      .fname { color: #e8e8f2; font-weight: 600; align-self: center; text-align: right;
               padding-right: 4px; }
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
      .wave { display: block; width: \(WaveBox.width)px; height: \(WaveBox.height)px;
              margin-top: 6px; }
      .wave line { stroke: #2c2c40; vector-effect: non-scaling-stroke; }
      .wave polygon { fill: #3f3f5e; }
      .card.playing .wave polygon { fill: #7aa2f7; }
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
    \(pairedSectionHTML("catalog", catalog))
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
