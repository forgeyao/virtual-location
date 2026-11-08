#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
mkdir -p .build
swiftc -parse-as-library Sources/VirtualLocation/Coordinate.swift Sources/VirtualLocation/MapCoordinates.swift Sources/VirtualLocation/FavoriteLocation.swift Sources/VirtualLocation/AppPreferences.swift Sources/VirtualLocation/PlaceSuggestions.swift Sources/VirtualLocation/AppModel.swift Sources/VirtualLocation/Backend.swift tests-swift/CoordinateChecks.swift -o .build/coordinate-checks
exec .build/coordinate-checks
