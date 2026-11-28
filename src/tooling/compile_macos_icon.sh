# Invoked by the packager with the manifest-relative inputs resolved.
set -eu
source_icon=$1
resources=$2
minimum_macos=$3
prebuilt=$4
name=$5

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/native-icon.XXXXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# Read the marketing version, not actool's internal bundle build number.
supports_icon_composer() {
    [ -x "$1" ] || return 1
    "$1" --version > "$work/version.plist" || return 1
    version=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.actool.version:short-bundle-version' "$work/version.plist") || return 1
    major=${version%%.*}
    case "$major" in ''|*[!0-9]*) return 1 ;; esac
    [ "$major" -ge 26 ] && return 0
    printf 'actool %s at %s requires an upgrade to Xcode 26 or later\n' "$version" "$1" >&2
    return 1
}

if [ "${DEVELOPER_DIR+x}" = x ]; then
    # xcrun also accepts the Xcode bundle as its developer directory.
    case "${DEVELOPER_DIR%/}" in
        *.app) DEVELOPER_DIR="${DEVELOPER_DIR%/}/Contents/Developer" ;;
    esac
    actool="$DEVELOPER_DIR/usr/bin/actool"
    [ -n "$DEVELOPER_DIR" ] && supports_icon_composer "$actool" ||
        fail "No usable actool in DEVELOPER_DIR='$DEVELOPER_DIR'. Set it to the developer directory of Xcode 26 or later."
else
    actool=$(/usr/bin/xcrun --find actool 2>/dev/null) || actool=
    if ! supports_icon_composer "$actool"; then
        actool=
        for candidate in /Applications/*.app/Contents/Developer; do
            [ -x "$candidate/usr/bin/actool" ] || continue
            app=${candidate%/Contents/Developer}
            [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" = com.apple.dt.Xcode ] || continue
            export DEVELOPER_DIR="$candidate"
            if supports_icon_composer "$candidate/usr/bin/actool"; then
                actool="$candidate/usr/bin/actool"
                break
            fi
        done
        [ -n "$actool" ] || fail "Cannot find actool from Xcode 26 or later. Install Xcode in /Applications or set DEVELOPER_DIR to its developer directory."
    fi
fi

# actool derives the catalog name from the directory and requires the
# lowercase .icon extension. Stage under the same name Info.plist uses.
cp -R "$source_icon/." "$work/$name.icon" || fail "Cannot read '$source_icon'. Supply an Icon Composer directory containing icon.json."
mkdir "$work/out"

# Compile in a fresh directory so a previous build's catalog or .icns
# cannot disguise a missing output. Keep actool diagnostics on the CLI.
"$actool" "$work/$name.icon" --compile "$work/out" --platform macosx --target-device mac \
    --minimum-deployment-target "$minimum_macos" --app-icon "$name" --include-all-app-icons \
    --output-partial-info-plist "$work/out/info.plist" --output-format human-readable-text --warnings --notices ||
    fail "actool could not compile '$source_icon'. Check icon.json and its layers in Icon Composer."

[ -s "$work/out/Assets.car" ] || fail "actool produced no Assets.car for '$source_icon'. Check the macOS artwork in Icon Composer."
if [ -n "$prebuilt" ]; then
    legacy="$prebuilt"
    filename=${prebuilt##*/}
else
    legacy="$work/out/$name.icns"
    filename="$name.icns"
fi
[ -s "$legacy" ] && [ "$(head -c 4 "$legacy")" = icns ] ||
    fail "Missing or invalid legacy icon '$legacy'. Supply a valid .icns in icons or check the macOS artwork in Icon Composer."
cp "$legacy" "$resources/$filename"
mv -f "$work/out/Assets.car" "$resources/Assets.car"
