// Orbe 補完エンジンの prebuilt バンドル生成。
// trim・改変した inshellisense runtime と curated withfig spec を 1 ファイルへ束ねて
// `app/completion-engine.js` を更新する。JSC が evaluateScript で読む IIFE。
// 再生成手順は README.md。Node はこのビルド時だけ必要で、.app ビルドには不要。
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../app/completion-engine.js");

// @withfig/autocomplete の package.json `exports` は `.`/`./dynamic` のみ公開し
// `./build/<cmd>.js` を塞ぐ（上流は dynamic import の絶対パスで回避）。curated spec を
// 静的 import するため、build/* を node_modules 内の実ファイル絶対パスへ解決する plugin。
const withfigBuildPath = path.join(here, "node_modules/@withfig/autocomplete/build/");
const resolveWithfigBuild = {
  name: "withfig-build",
  setup(b) {
    b.onResolve({ filter: /^@withfig\/autocomplete\/build\// }, (a) => ({
      path: path.join(withfigBuildPath, a.path.replace("@withfig/autocomplete/build/", "")),
    }));
  },
};

await build({
  entryPoints: [path.join(here, "src/engine.ts")],
  outfile: out,
  bundle: true,
  format: "iife",
  // JSC は Safari ベース。spec 群は browserslist で safari>=15 を想定して prebuilt 済み。
  target: ["safari15"],
  platform: "browser",
  legalComments: "none",
  minify: true,
  charset: "utf8",
  plugins: [resolveWithfigBuild],
});

console.log(`built ${path.relative(process.cwd(), out)}`);
