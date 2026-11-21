#!/bin/sh
# Builds SmallClock (SpringBoard tweak + settings pane) for the bootstrap
# Apelin is building for. Both slices, arm64 and arm64e, go into one binary:
# this device's linker warns about the arm64e ABI but produces a slice that
# loads on arm64e devices.
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
APELIN_PREFIX="${APELIN_PREFIX-}"
stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT

NAME=SmallClock
VERSION=1.2.0
PKGID=com.evander.smallclock
PREFS_NAME=SmallClockPrefs
PREFS_DEV=/usr/share/apelin/development/wiki.qaq.apelin.dev.preferences/support

cd "${APELIN_PROJECT_ROOT:?}"

jail="${APELIN_PREFIX-}"
dylibdir="${stage:?}${jail}/Library/MobileSubstrate/DynamicLibraries"
bundledir="${stage:?}${jail}/Library/PreferenceBundles/${PREFS_NAME}.bundle"
entrydir="${stage:?}${jail}/Library/PreferenceLoader/Preferences"
builddir="${stage:?}/build"
mkdir -p "${dylibdir:?}" "${bundledir:?}" "${entrydir:?}" "${builddir:?}"

for arch in arm64 arm64e; do
	clang -dynamiclib -arch "${arch}" \
		-miphoneos-version-min=16.0 \
		-fobjc-arc -fvisibility=hidden -fno-objc-arc-exceptions \
		-O2 -g \
		-DAPELIN_PACKAGE_ID="\"${PKGID}\"" \
		-DAPELIN_VERSION="\"${VERSION}\"" \
		-DAPELIN_BUILD_ID="\"${APELIN_BUILD_ID}\"" \
		-framework Foundation -framework UIKit -framework CoreGraphics \
		Sources/Tweak.m -o "${builddir:?}/${NAME}.${arch}.dylib"

	clang -bundle -arch "${arch}" \
		-miphoneos-version-min=16.0 \
		-fobjc-arc -O2 -g \
		-DAPELIN_PACKAGE_ID="\"${PKGID}\"" \
		-I"${PREFS_DEV:?}/include" \
		-F"${PREFS_DEV:?}/stubs" -framework Preferences \
		-framework Foundation -framework UIKit \
		Sources/Prefs.m -o "${builddir:?}/${PREFS_NAME}.${arch}"
done

lipo -create "${builddir:?}/${NAME}.arm64.dylib" "${builddir:?}/${NAME}.arm64e.dylib" \
	-output "${dylibdir:?}/${NAME}.dylib"
ldid -S "${dylibdir:?}/${NAME}.dylib"
cp apelin/SmallClock.plist "${dylibdir:?}/${NAME}.plist"

lipo -create "${builddir:?}/${PREFS_NAME}.arm64" "${builddir:?}/${PREFS_NAME}.arm64e" \
	-output "${bundledir:?}/${PREFS_NAME}"
ldid -S "${bundledir:?}/${PREFS_NAME}"
cp Resources/Root.plist "${bundledir:?}/Root.plist"
cp Resources/SmallClockPrefs-Info.plist "${bundledir:?}/Info.plist"
cp Resources/SmallClock-LoaderEntry.plist "${entrydir:?}/${NAME}.plist"

mkdir -p "${stage:?}/DEBIAN"
cat > "${stage:?}/DEBIAN/control" <<EOF
Package: ${PKGID}
Version: ${VERSION}
Architecture: ${APELIN_ARCHITECTURE}
Name: SmallClock
Description: 把锁屏的大时钟缩小到日期行里，日期与时间排成一行；设置里可开关。
Maintainer: evander <evander@users.noreply.github.com>
Author: evander
Section: Tweaks
Depends: mobilesubstrate, preferenceloader
EOF

dpkg-deb -b --root-owner-group "${stage:?}" "${APELIN_PACKAGE_DIR:?}/"
