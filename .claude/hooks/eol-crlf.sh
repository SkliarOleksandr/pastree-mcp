#!/bin/sh
#
# Restores CRLF wherever .gitattributes says `eol=crlf` and the working copy
# drifted to LF. Runs as a PostToolUse hook after Bash/Write/Edit, because an
# in-place edit from a POSIX shell (git-bash perl/sed read through the crlf
# layer and write without it) converts a whole Delphi source silently, and the
# index is LF for everything so no diff ever shows it. The pre-commit hook in
# .githooks/ is the same check as a hard gate; this one just keeps the tree
# clean as it goes. ~70 ms over the whole repository.
set -e
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 0

FIXED=""
for F in $(git ls-files --eol |
    awk -F'\t' '$1 ~ /w[/]lf/ && $1 ~ /eol=crlf/ { print $2 }'); do
  perl -pe 's/\r?\n/\r\n/' "$F" > "$F.eoltmp" && mv "$F.eoltmp" "$F"
  FIXED="$FIXED $F"
done

if [ -n "$FIXED" ]; then
  echo "eol-crlf: restored CRLF (.gitattributes eol=crlf) in:$FIXED"
fi
