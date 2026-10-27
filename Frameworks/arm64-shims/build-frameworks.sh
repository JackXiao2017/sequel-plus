#! /bin/bash
#
#  build-frameworks.sh
#  sequel-pro
#
#  Rebuilds the prebuilt third-party frameworks in ../ as universal
#  (arm64 + x86_64) binaries. The originals shipped i386/x86_64 only.
#
#  Parameters: $1 -- Path to a checkout of github.com/Sequel-Ace/shortcutrecorder
#              $2 -- Path to an extracted Sparkle 1.27.x release (contains Sparkle.framework)
#

set -euo pipefail

SHIMS="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORKS="$(dirname "$SHIMS")"
SR_SRC="$1/trunk/Framework"
SPARKLE_SRC="$2/Sparkle.framework"

CFLAGS=(-arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -fno-objc-arc -O2 -w)

# build_framework <name> <install name prefix> <header dir> <sources...>
build_framework() {
	local name="$1" prefix="$2" headers="$3"
	shift 3
	local version="$FRAMEWORKS/$name.framework/Versions/A"

	mkdir -p "$version/Headers" "$version/Resources"
	clang "${CFLAGS[@]}" -dynamiclib -F"$FRAMEWORKS" -I"$headers" \
		-install_name "$prefix/../Frameworks/$name.framework/Versions/A/$name" \
		-framework Cocoa -framework Carbon \
		-o "$version/$name.new" "$@"
	mv "$version/$name.new" "$version/$name"
	codesign --force --sign - "$version/$name"
	echo "$name: $(lipo -archs "$version/$name")"
}

# Growl, FeedbackReporter and UniversalDetector keep their existing headers
build_framework Growl @executable_path "$FRAMEWORKS/Growl.framework/Headers" "$SHIMS/Growl.m"
build_framework FeedbackReporter @loader_path "$FRAMEWORKS/FeedbackReporter.framework/Headers" "$SHIMS/FeedbackReporter.m"
build_framework UniversalDetector @executable_path "$FRAMEWORKS/UniversalDetector.framework/Headers" "$SHIMS/UniversalDetector.m"

# ShortcutRecorder is built from Sequel Ace's maintained 1.x fork
SR="$FRAMEWORKS/ShortcutRecorder.framework/Versions/A"
rm -rf "$SR/Headers" "$SR/Resources"
mkdir -p "$SR/Headers" "$SR/Resources"
cp "$SR_SRC"/ShortcutRecorder.h "$SR_SRC"/Source/*.h "$SR/Headers/"
cp -R "$SR_SRC"/Images/* "$SR_SRC"/Localizations/* "$SR/Resources/"
sed -e 's/${EXECUTABLE_NAME}/ShortcutRecorder/; s/${PRODUCT_BUNDLE_IDENTIFIER}/net.wafflesoftware.ShortcutRecorder.framework/' \
	"$SR_SRC/SR_LeopardFramework-Info.plist" > "$SR/Resources/Info.plist"
build_framework ShortcutRecorder @loader_path "$SR/Headers" "$SR_SRC"/Source/*.m

# Sparkle 1.27 is a universal drop-in replacement with the same SUUpdater API
rm -rf "$FRAMEWORKS/Sparkle.framework"
ditto "$SPARKLE_SRC" "$FRAMEWORKS/Sparkle.framework"
echo "Sparkle: $(lipo -archs "$FRAMEWORKS/Sparkle.framework/Sparkle")"
