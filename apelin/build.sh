#!/bin/sh
# Builds the SmallClock tweak for the bootstrap Apelin is building for.
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
APELIN_PREFIX="${APELIN_PREFIX-}"
stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT

NAME=SmallClock
VERSION=1.0.0
PKGID=com.evander.smallclock

cd "${APELIN_PROJECT_ROOT:?}"

dylibdir="${stage:?}${APELIN_PREFIX-}/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "${dylibdir:?}"

# This device's userland is arm64 (A11), and its linker refuses arm64e;
# an arm64 slice loads on arm64e devices too.
clang -dynamiclib -arch arm64 \
	-miphoneos-version-min=16.0 \
	-fobjc-arc -fvisibility=hidden -fno-objc-arc-exceptions \
	-O2 -g \
	-DAPELIN_PACKAGE_ID="\"${PKGID}\"" \
	-DAPELIN_VERSION="\"${VERSION}\"" \
	-DAPELIN_BUILD_ID="\"${APELIN_BUILD_ID}\"" \
	-framework Foundation -framework UIKit -framework CoreGraphics \
	Sources/Tweak.m -o "${dylibdir:?}/${NAME}.dylib"

ldid -S "${dylibdir:?}/${NAME}.dylib"
cp apelin/SmallClock.plist "${dylibdir:?}/${NAME}.plist"

mkdir -p "${stage:?}/DEBIAN"
cat > "${stage:?}/DEBIAN/control" <<EOF
Package: ${PKGID}
Version: ${VERSION}
Architecture: ${APELIN_ARCHITECTURE}
Name: SmallClock
Description: 把锁屏的大时钟缩小到日期行里，日期与时间排成一行。
Maintainer: evander <evander@users.noreply.github.com>
Author: evander
Section: Tweaks
Depends: mobilesubstrate
EOF

dpkg-deb -b --root-owner-group "${stage:?}" "${APELIN_PACKAGE_DIR:?}/"
