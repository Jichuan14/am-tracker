#!/bin/zsh
set -eu

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$project_root/app-source"
arch="$(/usr/bin/uname -m)"
if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--skip-tests" ]]; }; then
  print -u2 "Usage: $0 [--skip-tests]"
  exit 2
fi
if [[ "$arch" != "arm64" ]]; then
  print -u2 "This beta package must be built on an Apple Silicon Mac."
  exit 1
fi
"$source_root/build.sh" Release "$@"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_root/Info.plist")"
[[ "$version" == <->.<->.<-> ]] || { print -u2 "Invalid app version."; exit 1; }
asset="AM-Track-$version-beta.4-macOS-arm64.zip"
stage_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}am-track-package.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT
app_root="$stage_root/AM Track.app"
/bin/mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources" "$project_root/dist"

# Reconstruct the app from required files only. Never copy a working data folder.
/bin/cp "$source_root/Info.plist" "$app_root/Contents/Info.plist"
for executable in AMTrack AMQueue; do
  /bin/cp "$source_root/.build/Release/AM Track.app/Contents/MacOS/$executable" "$app_root/Contents/MacOS/$executable"
  minimum="$(/usr/bin/otool -l "$app_root/Contents/MacOS/$executable" | /usr/bin/awk '/LC_BUILD_VERSION/ { found=1 } found && $1=="minos" { print $2; exit }')"
  [[ "$minimum" == "13.0" ]] || { print -u2 "$executable has unexpected minimum macOS version: $minimum"; exit 1; }
done
for resource in sample library playback play catalog; do
  /bin/cp "$source_root/Resources/$resource.js" "$app_root/Contents/Resources/$resource.js"
done
/usr/bin/codesign --force --sign - --identifier org.amtrack.app.queue "$app_root/Contents/MacOS/AMQueue"
/usr/bin/codesign --force --sign - --identifier org.amtrack.app "$app_root"
/usr/bin/codesign --verify --deep --strict "$app_root"
/bin/cp "$project_root/INSTALL.txt" "$stage_root/Install AM Track.txt"

# Exclude extended attributes and resource forks, which can contain local metadata.
/usr/bin/ditto -c -k --norsrc --noextattr "$stage_root" "$project_root/dist/$asset"
(cd "$project_root/dist" && /usr/bin/shasum -a 256 "$asset" > "$asset.sha256")
print "Package: $project_root/dist/$asset"
print "Checksum: $project_root/dist/$asset.sha256"
print "Distribution: Apple Silicon beta, ad hoc signed, not Apple-notarized."
