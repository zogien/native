#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$repo/zig-out/bin/native"
work="$(mktemp -d "${TMPDIR:-/tmp}/native-composer-test.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
project="$work/Beacon Project"
bundle="$work/Beacon.app"
resources="$bundle/Contents/Resources"
mkdir -p "$project/assets"
cp -R "$repo/tests/fixtures/Beacon.icon" "$project/Beacon.icon"
cp "$repo/assets/icon.png" "$project/assets/icon.png"
cp "$repo/assets/icon.icns" "$project/Legacy.icns"
manifest="$project/app.json"
write_manifest() {
    printf '{"id":"dev.example.beacon","name":"beacon","version":"1.0.0","icons":[%s]}\n' "$1" > "$manifest"
}
package() {
    "$cli" package --target macos --manifest "$manifest" --output "$bundle" \
        --binary /bin/ls --assets "$project/assets" --signing "$1"
}
expect_failure() {
    local diagnostic="$1"
    shift
    if "$@" > "$work/failure.log" 2>&1; then
        echo "Expected failure: $*" >&2
        exit 1
    fi
    grep -F "$diagnostic" "$work/failure.log" || { cat "$work/failure.log" >&2; exit 1; }
}

write_manifest '"Beacon.icon","assets/icon.png"'
DEVELOPER_DIR="$work/absent" "$cli" validate "$manifest"
package none
plist="$bundle/Contents/Info.plist"
test "$(plutil -extract CFBundleIconName raw "$plist")" = AppIcon
test "$(plutil -extract CFBundleIconFile raw "$plist")" = AppIcon.icns
test "$(plutil -extract LSMinimumSystemVersion raw "$plist")" = 11.0
iconutil --convert iconset "$resources/AppIcon.icns" --output "$work/legacy.iconset"
test -s "$work/legacy.iconset/icon_128x128.png"
check_layered_icon() {
    assetutil --info "$1" > "$work/catalog.json"
    python3 - "$work/catalog.json" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as catalog:
    entries = json.load(catalog)
assert any(e.get("Name") == sys.argv[2] and e.get("AssetType") == "IconImageStack" for e in entries)
PY
}
check_layered_icon "$resources/Assets.car" AppIcon

# Reuse the same bundle when switching to PNG. A clean PNG build is the
# reference in CI. Pass a baseline CLI as $1 to compare across revisions.
(
    cd "$project"
    args=(package --target macos --binary /bin/ls --signing none)
    write_manifest '"assets/icon.png"'
    "${1:-$cli}" "${args[@]}" --output "$work/reference/beacon.app"

    check_repack() {
        local output="$1"
        shift
        write_manifest '"Beacon.icon","assets/icon.png"'
        "$cli" "${args[@]}" "$@"
        test -s "$output/Contents/Resources/Assets.car"
        write_manifest '"assets/icon.png"'
        "$cli" "${args[@]}" "$@"
        diff -qr "$work/reference/beacon.app" "$output"
    }

    check_repack zig-out/package/beacon.app
    check_repack "$work/fixed output/beacon.app" --output "$work/fixed output/beacon.app"

    # Supply a real independent catalog to the PNG bundle. A failed
    # Composer build must not claim it or delete it on the next PNG build.
    mkdir "$work/user-art"
    /bin/sh "$repo/src/tooling/compile_macos_icon.sh" "$project/Beacon.icon" "$work/user-art" 11.0 "" UserBadge
    user_catalog="$work/user-art/Assets.car"
    check_failed_repack() {
        local output="$1" failure="$2"
        shift 2
        local catalog="$output/Contents/Resources/Assets.car" plist="$output/Contents/Info.plist"
        write_manifest '"assets/icon.png"'
        cp "$user_catalog" "$catalog"
        "$cli" "${args[@]}" "$@"
        cmp "$user_catalog" "$catalog"
        cp "$plist" "$work/before.plist"

        write_manifest '"Beacon.icon","assets/icon.png"'
        if [ "$failure" = missing-tool ]; then
            DEVELOPER_DIR="$work/absent" expect_failure "No usable actool" "$cli" "${args[@]}" "$@"
        else
            printf '{' > Beacon.icon/icon.json
            expect_failure "actool could not compile" "$cli" "${args[@]}" "$@"
            cp "$repo/tests/fixtures/Beacon.icon/icon.json" Beacon.icon/icon.json
        fi
        cmp "$work/before.plist" "$plist"
        cmp "$user_catalog" "$catalog"

        write_manifest '"assets/icon.png"'
        "$cli" "${args[@]}" "$@"
        cmp "$user_catalog" "$catalog"
        cmp "$work/before.plist" "$plist"
    }
    check_failed_repack "$work/fixed output/beacon.app" missing-tool --output "$work/fixed output/beacon.app"
    check_failed_repack zig-out/package/beacon.app broken-source

    # Absolute --assets overlays Resources directly. A locked plist must
    # leave the existing layered bundle readable after the copy rolls back.
    mkdir "$work/absolute assets"
    cp "$user_catalog" "$work/absolute assets/Assets.car"
    check_layered_icon "$work/absolute assets/Assets.car" UserBadge
    cp "$plist" "$work/original-Info.plist"
    cp "$resources/AppIcon.icns" "$work/original-AppIcon.icns"
    cp "$resources/Assets.car" "$work/original-Assets.car"
    check_locked_repack() (
        chflags uchg "$plist"
        trap 'chflags nouchg "$plist"' EXIT
        expect_failure PermissionDenied "$cli" "${args[@]}" --output "$bundle" --assets "$work/absolute assets"
        grep -F 'com.apple.actool.compilation-results' "$work/failure.log"
        cmp "$work/original-Info.plist" "$plist"
        cmp "$work/original-AppIcon.icns" "$resources/AppIcon.icns"
        cmp "$work/original-Assets.car" "$resources/Assets.car"
        check_layered_icon "$resources/Assets.car" AppIcon
    )
    write_manifest '"Beacon.icon","assets/icon.png"'
    check_locked_repack

    # The new manifest can also select a different fallback while the asset
    # tree contains a file with the old fallback's name.
    cp "$repo/assets/icon.icns" "$work/absolute assets/AppIcon.icns"
    write_manifest '"Legacy.icns","Beacon.icon"'
    check_locked_repack
    test ! -e "$resources/Legacy.icns"
    "$cli" "${args[@]}" --output "$bundle" --assets "$work/absolute assets"
    test "$(plutil -extract CFBundleIconFile raw "$plist")" = Legacy.icns
    cmp "$project/Legacy.icns" "$resources/Legacy.icns"
    cmp "$work/absolute assets/AppIcon.icns" "$resources/AppIcon.icns"
    check_layered_icon "$resources/Assets.car" AppIcon

    # If publishing the staged plist fails, restore both previous resources.
    output="$work/fixed output/beacon.app"
    mv "$output/Contents/Info.plist" "$work/original.plist"
    mkdir "$output/Contents/Info.plist"
    cp "$output/Contents/Resources/AppIcon.icns" "$work/before.icns"
    write_manifest '"Beacon.icon","assets/icon.png"'
    if "$cli" "${args[@]}" --output "$output"; then
        echo "Expected failure publishing Info.plist to a directory" >&2
        exit 1
    fi
    cmp "$user_catalog" "$output/Contents/Resources/Assets.car"
    cmp "$work/before.icns" "$output/Contents/Resources/AppIcon.icns"
)

bundle="$work/Signed Beacon.app"
resources="$bundle/Contents/Resources"
plist="$bundle/Contents/Info.plist"
write_manifest '"Legacy.icns","Beacon.icon","assets/icon.png"'
package adhoc
codesign --verify --deep --strict "$bundle"
test "$(plutil -extract CFBundleIconFile raw "$plist")" = Legacy.icns
test "$(plutil -extract CFBundleIconName raw "$plist")" = AppIcon
cmp "$resources/Legacy.icns" "$project/Legacy.icns"

DEVELOPER_DIR="$work/absent" expect_failure "No usable actool in DEVELOPER_DIR" package none
printf '{' > "$project/Beacon.icon/icon.json"
expect_failure "actool could not compile" package none
grep -F "com.apple.actool.errors" "$work/failure.log"

# Exercise the compiler in isolation. Pin DEVELOPER_DIR so the installed
# Xcode cannot hide a missing tool, old version, or failed compilation.
compiler=(/bin/sh "$repo/src/tooling/compile_macos_icon.sh" "$project/Beacon.icon" "$resources" 11.0 "" AppIcon)
DEVELOPER_DIR="$work/absent" expect_failure "No usable actool" "${compiler[@]}"
mkdir -p "$work/old/usr/bin"
cat > "$work/old/usr/bin/actool" <<'TOOL'
#!/bin/sh
if [ "$1" = --version ]; then
    printf '<plist version="1.0"><dict><key>com.apple.actool.version</key><dict><key>short-bundle-version</key><string>%s</string></dict></dict></plist>\n' "$TEST_VERSION"
    exit 0
fi
echo "fixture compiler diagnostic" >&2
exit "$TEST_STATUS"
TOOL
chmod +x "$work/old/usr/bin/actool"
export DEVELOPER_DIR="$work/old"
TEST_VERSION=16.4 expect_failure "actool 16.4" "${compiler[@]}"
TEST_VERSION=26.0 TEST_STATUS=3 expect_failure "actool could not compile" "${compiler[@]}"
grep -F "fixture compiler diagnostic" "$work/failure.log"
TEST_VERSION=26.0 TEST_STATUS=0 expect_failure "actool produced no Assets.car" "${compiler[@]}"
