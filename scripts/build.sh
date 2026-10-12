#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/local
# No package dependencies. Direct compilation also works when SwiftPM's bundled
# manifest libraries don't match the installed Command Line Tools compiler.
if [[ "${SIGNATURE_KEEPER_UNIVERSAL:-0}" == 1 ]]; then
    SIGNATURE_KEEPER_ARCH=arm64 zsh scripts/compile.sh -O Sources/SignatureKeeper/*.swift -o .build/local/SignatureKeeper-arm64
    SIGNATURE_KEEPER_ARCH=x86_64 zsh scripts/compile.sh -O Sources/SignatureKeeper/*.swift -o .build/local/SignatureKeeper-x86_64
    lipo -create .build/local/SignatureKeeper-arm64 .build/local/SignatureKeeper-x86_64 -output .build/local/SignatureKeeper
else
    zsh scripts/compile.sh -O Sources/SignatureKeeper/*.swift -o .build/local/SignatureKeeper
fi
bundle="$PWD/dist/Подпись.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/local/SignatureKeeper "$bundle/Contents/MacOS/SignatureKeeper"
cp Info.plist "$bundle/Contents/Info.plist"
zsh scripts/compile.sh scripts/Icon.swift -o .build/local/icon-builder
.build/local/icon-builder .build/local/AppIcon.iconset
iconutil -c icns .build/local/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
rm -f "$bundle/Contents/Resources/Defaults.json"
if [[ "${SIGNATURE_KEEPER_INCLUDE_LOCAL_DEFAULTS:-0}" == 1 && -f Defaults.json ]]; then
    cp Defaults.json "$bundle/Contents/Resources/Defaults.json"
fi
codesign --force --sign - "$bundle"
print -r -- "$bundle"
