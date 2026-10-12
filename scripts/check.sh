#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/local
zsh scripts/compile.sh Sources/SignatureKeeper/Models.swift Sources/SignatureKeeper/Engine.swift Tests/checks.swift -o .build/local/checks
.build/local/checks
