#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
mkdir -p .build assets/brand
swiftc -module-cache-path .build/ModuleCache Sources/VirtualLocation/BrandArtwork.swift scripts/render-logo.swift -o .build/render-logo
.build/render-logo assets/brand
iconutil -c icns assets/brand/AppIcon.iconset -o assets/brand/AppIcon.icns
swift build -c release --build-system native
exec .venv/bin/python scripts/package_app.py
