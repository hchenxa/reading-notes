#!/bin/bash
# Auto-generate _sidebar.md from directory structure
# Runs in GitHub Actions before deployment

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SIDEBAR="$ROOT/_sidebar.md"

# Directories to skip
SKIP_DIRS="node_modules|\.venv|\.git|\.github|\.claude|_sass|_includes|kind|python/sample|python/pytest|appium/sample|javascript/example|javascript/project|go/gin/templates|go/rpc|go/socket|go/tips|go/go-kit"

echo "* [Home](/)" > "$SIDEBAR"

# Find all directories containing README.md (top-level topics)
for dir in $(find "$ROOT" -maxdepth 1 -type d | sort); do
  dirname=$(basename "$dir")

  # Skip root, hidden dirs, and excluded dirs
  if [ "$dir" = "$ROOT" ] || [[ "$dirname" =~ ^\. ]] || echo "$dirname" | grep -qE "^($SKIP_DIRS)$"; then
    continue
  fi

  # Skip if no README.md
  if [ ! -f "$dir/README.md" ]; then
    continue
  fi

  # Extract title from first H1 heading, fallback to directory name
  title=$(grep -m1 '^# ' "$dir/README.md" | sed 's/^# //')
  if [ -z "$title" ]; then
    title="$dirname"
  fi

  echo "" >> "$SIDEBAR"
  echo "* **$title**" >> "$SIDEBAR"
  echo "  * [概览](/$dirname/)" >> "$SIDEBAR"

  # Find sub-pages (non-README .md files and subdirectory READMEs)
  for md in $(find "$dir" -name "*.md" ! -name "README.md" -maxdepth 1 | sort); do
    fname=$(basename "$md" .md)
    sub_title=$(grep -m1 '^# ' "$md" | sed 's/^# //')
    if [ -z "$sub_title" ]; then
      sub_title="$fname"
    fi
    echo "  * [$sub_title](/$dirname/$fname)" >> "$SIDEBAR"
  done

  # Find subdirectory READMEs (one level deep)
  for subdir in $(find "$dir" -mindepth 1 -maxdepth 1 -type d | sort); do
    subdirname=$(basename "$subdir")

    # Skip excluded dirs
    if echo "$dirname/$subdirname" | grep -qE "$SKIP_DIRS"; then
      continue
    fi

    if [ -f "$subdir/README.md" ]; then
      sub_title=$(grep -m1 '^# ' "$subdir/README.md" | sed 's/^# //')
      if [ -z "$sub_title" ]; then
        sub_title="$subdirname"
      fi
      echo "  * [$sub_title](/$dirname/$subdirname/)" >> "$SIDEBAR"
    fi
  done
done

echo "Generated _sidebar.md"
