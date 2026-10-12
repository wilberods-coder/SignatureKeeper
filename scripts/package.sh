#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
SIGNATURE_KEEPER_INCLUDE_LOCAL_DEFAULTS=0 zsh scripts/build.sh
archive="$PWD/dist/SignatureKeeper-macOS.zip"
rm -f "$archive"
ditto -c -k --keepParent "$PWD/dist/Подпись.app" "$archive"
(cd dist && LC_ALL=C LANG=C /usr/bin/shasum -a 256 SignatureKeeper-macOS.zip > SHA256SUMS.txt)
print -r -- "$archive"
