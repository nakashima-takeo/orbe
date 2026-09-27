#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.8.0"
log_dir="${HOME}/.orbe/logs"

log() {
  printf '%s\n' "$*" >&2
}

function build {
  local target="$1"
  compile() {
    swift build -c "$target"
  }
  compile
}

function test_all() (
  swift test
)

deploy::remote() {
  # deploy() { is inside a comment
  echo "deploying $VERSION"
  cat <<'DOC'
fake() {
DOC
}

case "${1:-}" in
  build) build release ;;
  *) log "usage" ;;
esac
