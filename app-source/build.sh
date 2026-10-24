#!/bin/zsh
set -eu
source_root="$(cd "$(dirname "$0")" && pwd)"
# Usage: ./app-source/build.sh [Debug|Release] [--skip-tests]
# Tests run by default; --skip-tests builds and signs the app only.
configuration=Debug
skip_tests=false
for argument in "$@"; do
  case "$argument" in
    Debug|Release) configuration="$argument" ;;
    --skip-tests) skip_tests=true ;;
    *) print -u2 "Usage: $0 [Debug|Release] [--skip-tests]"; exit 2 ;;
  esac
done
case "$configuration" in
  Debug) optimization=-Onone; build_root="$source_root/.build" ;;
  Release) optimization=-O; build_root="$source_root/.build/Release" ;;
esac
app_root="$build_root/AM Track.app"
/bin/mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
/bin/cp "$source_root/Info.plist" "$app_root/Contents/Info.plist"
/bin/cp "$source_root/Resources/playback.js" "$source_root/Resources/sample.js" "$source_root/Resources/library.js" "$source_root/Resources/play.js" "$source_root/Resources/catalog.js" "$app_root/Contents/Resources/"
/usr/bin/xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -Wno-incompatible-pointer-types -framework Foundation -framework AppKit \
  "$source_root/BackgroundQueue.m" -o "$app_root/Contents/MacOS/AMQueue"
/usr/bin/codesign --force --sign - --identifier org.amtrack.app.queue "$app_root/Contents/MacOS/AMQueue"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target "$(/usr/bin/uname -m)-apple-macos13.0" "$optimization" \
  -module-cache-path "$source_root/.build/module-cache" \
  -framework AppKit -framework SwiftUI "$source_root/main.swift" "$source_root/HistoryStore.swift" "$source_root/Recommendations.swift" "$source_root/RecommendationRotation.swift" "$source_root/RecommendationRotationTests.swift" "$source_root/HistoryTests.swift" "$source_root/UnifiedHistory.swift" "$source_root/MusicPlayback.swift" "$source_root/MusicQueue.swift" "$source_root/AutomaticPlayback.swift" "$source_root/QueueLatency.swift" "$source_root/OneAheadTests.swift" "$source_root/CachedReserveTests.swift" "$source_root/CachedAlbumTests.swift" "$source_root/AlbumTaste.swift" "$source_root/RecommendationTests.swift" "$source_root/RecommendationReferenceTests.swift" \
  -o "$app_root/Contents/MacOS/AMTrack"
/usr/bin/codesign --force --sign - --identifier org.amtrack.app "$app_root"
if [[ "$skip_tests" == false ]]; then
/usr/bin/xcrun clang -fobjc-arc -Wno-incompatible-pointer-types -framework Foundation -framework AppKit \
  "$source_root/BackgroundQueueTests.m" -o "$source_root/.build/background-queue-tests"
"$source_root/.build/background-queue-tests"
"$app_root/Contents/MacOS/AMTrack" --self-test
/usr/bin/osascript -l JavaScript "$source_root/PlaybackScriptTests.js" "$source_root/Resources/play.js"
/usr/bin/osascript -l JavaScript "$source_root/CatalogScriptTests.js" "$source_root/Resources/catalog.js"

/usr/bin/osascript -l JavaScript "$source_root/PlaybackReadTests.js" "$source_root/Resources/playback.js"
fi
print "Built ($configuration, $optimization): $app_root"
