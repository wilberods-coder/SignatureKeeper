#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/local .build/compat
compiler=$(xcrun --find swiftc)
include_dir="${compiler:h:h}/include/swift"
extra=()
# Some upgraded CLT installations leave two declarations of SwiftBridging.
# Hide the obsolete declaration from this compilation via a local VFS overlay.
if [[ -f "$include_dir/module.modulemap" && -f "$include_dir/bridging.modulemap" ]] &&
   [[ "$(< "$include_dir/module.modulemap")" == *'module SwiftBridging'* ]] &&
   [[ "$(< "$include_dir/bridging.modulemap")" == *'module SwiftBridging'* ]]; then
    : > .build/compat/empty.modulemap
    overlay="$PWD/.build/compat/overlay.json"
    rm -f "$overlay"
    plutil -create xml1 "$overlay"
    plutil -insert version -integer 0 "$overlay"
    plutil -insert roots -array "$overlay"
    plutil -insert roots.0 -dictionary "$overlay"
    plutil -insert roots.0.type -string file "$overlay"
    plutil -insert roots.0.name -string "$include_dir/module.modulemap" "$overlay"
    plutil -insert roots.0.external-contents -string "$PWD/.build/compat/empty.modulemap" "$overlay"
    plutil -convert json "$overlay"
    extra=(-vfsoverlay "$overlay" -Xcc -ivfsoverlay -Xcc "$overlay")
fi
xcrun swiftc -swift-version 5 -parse-as-library -target "${SIGNATURE_KEEPER_ARCH:-$(uname -m)}-apple-macosx13.0" "${extra[@]}" "$@"
