#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
app_dir="$project_dir/Artifacts/KDS.app"
version="${KDS_VERSION:-0.1.0}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
    print -u2 "KDS_VERSION must be numeric, for example 0.1.0"
    exit 1
fi

swift build --package-path "$project_dir" -c release --arch arm64 --product KDS
swift build --package-path "$project_dir" -c release --arch x86_64 --product KDS

if [[ -d "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi
/bin/mkdir -p "$app_dir/Contents/MacOS"
/bin/cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/bin/lipo -create \
    "$project_dir/.build/arm64-apple-macosx/release/KDS" \
    "$project_dir/.build/x86_64-apple-macosx/release/KDS" \
    -output "$app_dir/Contents/MacOS/KDS"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$app_dir"
/usr/bin/codesign --verify --strict --verbose=2 "$app_dir"
/usr/bin/lipo -info "$app_dir/Contents/MacOS/KDS"
/usr/bin/du -sh "$app_dir"

