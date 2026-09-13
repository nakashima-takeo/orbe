#!/usr/bin/env bash
# Copy the tree-sitter query bundles into the app.
set -euo pipefail

APP="$1"
count=0
for bundle in .build/release/TreeSitter*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
  count=$((count + 1))
done
echo "copied $count bundles"
