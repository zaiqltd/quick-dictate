#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
DEST="/Applications/Quick Dictate.app"
if pgrep -x QuickDictate >/dev/null; then
  print "Quit Quick Dictate before installing an update so recordings are not interrupted."
  exit 1
fi
if [[ -d "$DEST" ]]; then
  # The previous app is kept, never deleted: in ~/work/_ARCHIVE when that folder exists (the
  # original author's Mac), otherwise in Application Support on any other Mac.
  if [[ -d "$HOME/work/_ARCHIVE" ]]; then
    ARCHIVE_DIR="$HOME/work/_ARCHIVE"
  else
    ARCHIVE_DIR="$HOME/Library/Application Support/Quick Dictate/previous-apps"
    mkdir -p "$ARCHIVE_DIR"
  fi
  BACKUP="$ARCHIVE_DIR/quick-dictate-$(date +%Y%m%d-%H%M%S).app"
  mv "$DEST" "$BACKUP"
  print "Previous app kept at: $BACKUP"
  if [[ -f "$HOME/work/_OPS/CHANGELOG.md" ]]; then
    print -r -- "- $(date +%Y-%m-%d): Archived previous Quick Dictate app from $DEST to $BACKUP. Restore: move it back to $DEST after moving the newer app aside." >> "$HOME/work/_OPS/CHANGELOG.md"
  fi
fi
ditto "build/Quick Dictate.app" "$DEST"
open "$DEST"
print "Installed: $DEST"
