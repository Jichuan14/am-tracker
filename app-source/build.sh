#!/bin/zsh
set -eu
source_root="$(cd "$(dirname "$0")" && pwd)"
app_root="$source_root/.build/AM Track.app"
/bin/mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
/bin/cp "$source_root/Info.plist" "$app_root/Contents/Info.plist"
/bin/cp "$source_root/Resources/sample.js" "$source_root/Resources/library.js" "$source_root/Resources/play.js" "$source_root/Resources/catalog.js" "$app_root/Contents/Resources/"
/usr/bin/xcrun clang -fobjc-arc -Wno-incompatible-pointer-types -framework Foundation -framework AppKit \
  "$source_root/BackgroundQueue.m" -o "$app_root/Contents/MacOS/AMQueue"
/usr/bin/codesign --force --sign - --identifier org.amtrack.app.queue "$app_root/Contents/MacOS/AMQueue"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -target "$(/usr/bin/uname -m)-apple-macos13.0" -Onone \
  -module-cache-path "$source_root/.build/module-cache" \
  -framework AppKit -framework SwiftUI "$source_root/main.swift" "$source_root/HistoryStore.swift" "$source_root/Recommendations.swift" "$source_root/HistoryTests.swift" "$source_root/UnifiedHistory.swift" "$source_root/MusicPlayback.swift" "$source_root/MusicQueue.swift" "$source_root/AlbumTaste.swift" "$source_root/RecommendationTests.swift" \
  -o "$app_root/Contents/MacOS/AMTrack"
/usr/bin/codesign --force --sign - --identifier org.amtrack.app "$app_root"
"$app_root/Contents/MacOS/AMTrack" --self-test
/usr/bin/osascript -l JavaScript "$source_root/PlaybackScriptTests.js" "$source_root/Resources/play.js"
print "Built: $app_root"
/usr/bin/osascript -l JavaScript "$source_root/CatalogScriptTests.js" "$source_root/Resources/catalog.js"
