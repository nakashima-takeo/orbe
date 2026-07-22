// curated subset の withfig spec（prebuilt build/*.js を静的 import）。
// 実用頻度上位の 37 コマンド＋自家 2 spec（claude/codex・上流に無い）のみ同梱
// （全 600+ の網羅はしない）。追加は本ファイルへ import を足して再生成するだけ（README）。
// 上流: @withfig/autocomplete build（package.json で版を pin）。
import git from "@withfig/autocomplete/build/git.js";
import npm from "@withfig/autocomplete/build/npm.js";
import pnpm from "@withfig/autocomplete/build/pnpm.js";
import yarn from "@withfig/autocomplete/build/yarn.js";
import docker from "@withfig/autocomplete/build/docker.js";
import dockerCompose from "@withfig/autocomplete/build/docker-compose.js";
import cargo from "@withfig/autocomplete/build/cargo.js";
import go from "@withfig/autocomplete/build/go.js";
import kubectl from "@withfig/autocomplete/build/kubectl.js";
import brew from "@withfig/autocomplete/build/brew.js";
import gh from "@withfig/autocomplete/build/gh.js";
import make from "@withfig/autocomplete/build/make.js";
import python from "@withfig/autocomplete/build/python.js";
import pip from "@withfig/autocomplete/build/pip.js";
import node from "@withfig/autocomplete/build/node.js";
import ssh from "@withfig/autocomplete/build/ssh.js";
import curl from "@withfig/autocomplete/build/curl.js";
import tar from "@withfig/autocomplete/build/tar.js";
import systemctl from "@withfig/autocomplete/build/systemctl.js";
import ls from "@withfig/autocomplete/build/ls.js";
import cd from "@withfig/autocomplete/build/cd.js";
import cat from "@withfig/autocomplete/build/cat.js";
import rm from "@withfig/autocomplete/build/rm.js";
import cp from "@withfig/autocomplete/build/cp.js";
import mv from "@withfig/autocomplete/build/mv.js";
import kill from "@withfig/autocomplete/build/kill.js";
import grep from "@withfig/autocomplete/build/grep.js";
import find from "@withfig/autocomplete/build/find.js";
import chmod from "@withfig/autocomplete/build/chmod.js";
import code from "@withfig/autocomplete/build/code.js";
import deno from "@withfig/autocomplete/build/deno.js";
import mkdir from "@withfig/autocomplete/build/mkdir.js";
import xcodebuild from "@withfig/autocomplete/build/xcodebuild.js";
import volta from "@withfig/autocomplete/build/volta.js";
import open from "@withfig/autocomplete/build/open.js";
import touch from "@withfig/autocomplete/build/touch.js";
import source from "@withfig/autocomplete/build/source.js";
import claude from "./claude.js";
import codex from "./codex.js";

// コマンド名 → figspec。loadSpec はこの表を同期参照する（JSC に dynamic import は無い）。
export const specRegistry: { [key: string]: Fig.Spec } = {
  git,
  npm,
  pnpm,
  yarn,
  docker,
  "docker-compose": dockerCompose,
  cargo,
  go,
  kubectl,
  brew,
  gh,
  make,
  python,
  pip,
  node,
  ssh,
  curl,
  tar,
  systemctl,
  ls,
  cd,
  cat,
  rm,
  cp,
  mv,
  kill,
  grep,
  find,
  chmod,
  code,
  deno,
  mkdir,
  xcodebuild,
  volta,
  open,
  touch,
  source,
  claude,
  codex,
};
