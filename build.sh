#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export THEOS="${THEOS:-$HOME/theos}"
export THEOS_PACKAGE_DIR="$ROOT"
export PATH="$THEOS/bin:${PATH:-}"

if [ ! -d "$THEOS" ]; then
    echo "Error: THEOS not found at $THEOS" >&2
    echo "Run ./build_dependencies.sh to set up the build environment." >&2
    exit 1
fi

if command -v brew >/dev/null 2>&1; then
    GNU_MAKE="$(brew --prefix make 2>/dev/null)/libexec/gnubin"
    if [ -d "$GNU_MAKE" ]; then
        export PATH="$GNU_MAKE:$PATH"
    fi
fi

if ! command -v make >/dev/null 2>&1; then
    echo "Error: make not found. Install with: brew install make" >&2
    exit 1
fi

echo "Building Gonerino..."
echo "  THEOS=$THEOS"
echo ""

make clean package FINALPACKAGE=1

echo ""
echo "Built .deb packages:"
ls -1 "$ROOT"/*.deb
