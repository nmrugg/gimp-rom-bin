#!/usr/bin/env bash
#
# Cross build file-rom-bin for Windows (GIMP 3.x) from Linux.
#
#   ./build/windows/cross-build.sh                 # -> ./file-rom-bin.exe
#   GIMP_VERSION=3.2.6 ./build/windows/cross-build.sh
#
# What it needs from the host:
#   * a mingw-w64 toolchain        (sudo apt install mingw-w64)
#   * curl, tar, zstd, python3, pkg-config
#
# Everything else it fetches by itself into $CACHE_DIR:
#   * the GIMP source tarball - used only for the libgimp*.def export lists
#     (which turn into Windows import libs) and the libgimp headers
#   * MSYS2's prebuilt Windows glib/gtk3/GEGL/babl/... dev packages
#
set -euo pipefail

GIMP_VERSION=${GIMP_VERSION:-3.2.2}
ARCH=${ARCH:-x86_64}                     # x86_64 (GIMP 3 Windows is 64 bit)
PLUGIN_VERSION=${PLUGIN_VERSION:-0.3.0}

TARGET_TRIPLE="${ARCH}-w64-mingw32"
CC="${TARGET_TRIPLE}-gcc"
WINDRES="${TARGET_TRIPLE}-windres"
DLLTOOL="${TARGET_TRIPLE}-dlltool"
OBJDUMP="${TARGET_TRIPLE}-objdump"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/src"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/gimp-rom-bin-winbuild}"
WORK="$CACHE_DIR/work-$ARCH-$GIMP_VERSION"
SYSROOT="$CACHE_DIR/msys2-$ARCH"
DEFS="$WORK/gimp-$GIMP_VERSION"
OUT="${OUT:-$ROOT/file-rom-bin.exe}"

for tool in "$CC" "$WINDRES" "$DLLTOOL" curl tar zstd python3 pkg-config; do
    command -v "$tool" >/dev/null || {
        echo "missing tool: $tool" >&2
        [ "$tool" = "$CC" ] && echo "  -> sudo apt install mingw-w64" >&2
        exit 1
    }
done

mkdir -p "$CACHE_DIR" "$WORK" "$SYSROOT/lib" "$WORK/winlibs" "$WORK/obj" "$WORK/winres"

echo "=== 1/5  GIMP $GIMP_VERSION source (headers + .def export lists)"
TARBALL="gimp-$GIMP_VERSION.tar.xz"
if [ ! -d "$DEFS/libgimp" ]; then
    curl -sSL --fail -o "$CACHE_DIR/$TARBALL" \
         "https://download.gimp.org/pub/gimp/v${GIMP_VERSION%.*}/$TARBALL"
    tar xf "$CACHE_DIR/$TARBALL" -C "$WORK"
    mv "$WORK/gimp-$GIMP_VERSION" "$DEFS" 2>/dev/null || true
fi
[ -d "$DEFS/libgimp" ] || { echo "could not unpack GIMP source into $DEFS" >&2; exit 1; }

# gimpversion.h is the only generated header a plug-in needs
if [ ! -f "$DEFS/libgimpbase/gimpversion.h" ]; then
    IFS=. read -r MAJ MIN MIC <<<"$GIMP_VERSION"
    sed -e "s/@GIMP_MAJOR_VERSION@/$MAJ/" -e "s/@GIMP_MINOR_VERSION@/$MIN/" \
        -e "s/@GIMP_MICRO_VERSION@/$MIC/" -e "s/@GIMP_VERSION@/$GIMP_VERSION/" \
        -e "s/@GIMP_API_VERSION@/${MAJ}.${MIN}/" \
        "$DEFS/libgimpbase/gimpversion.h.in" > "$DEFS/libgimpbase/gimpversion.h"
fi

echo "=== 2/5  Windows dependency sysroot (MSYS2 prebuilt packages)"
# gexiv2 is only needed for the libgimp headers (gimpmetadata.h includes it),
# the plug-in itself never links against it
MSYS2_ARCH="$ARCH" python3 "$ROOT/build/windows/fetch-msys2-deps.py" \
    "$SYSROOT" "$CACHE_DIR/msys2-dl" gegl-0.4 babl-0.1 gtk+-3.0 gexiv2 pkg:gettext-runtime

export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
# the shipped .pc files use the MSYS2 prefix (/mingw64), point them at our sysroot
pkg-config --define-prefix --cflags gegl-0.4 babl-0.1 gtk+-3.0 gexiv2 >/tmp/rombin-cf.$$
pkg-config --define-prefix --libs   gegl-0.4 babl-0.1 gtk+-3.0       >/tmp/rombin-lf.$$
CFLAGS_DEP=$(cat /tmp/rombin-cf.$$); LFLAGS_DEP=$(cat /tmp/rombin-lf.$$); rm -f /tmp/rombin-cf.$$ /tmp/rombin-lf.$$

echo "=== 3/5  import libs for the libgimp DLLs (from GIMP's own .def files)"
LIBS_LINK=()
for pair in "gimp:$DEFS/libgimp/gimp.def" \
            "gimpui:$DEFS/libgimp/gimpui.def" \
            "gimpbase:$DEFS/libgimpbase/gimpbase.def" \
            "gimpcolor:$DEFS/libgimpcolor/gimpcolor.def" \
            "gimpconfig:$DEFS/libgimpconfig/gimpconfig.def" \
            "gimpmath:$DEFS/libgimpmath/gimpmath.def" \
            "gimpmodule:$DEFS/libgimpmodule/gimpmodule.def" \
            "gimpwidgets:$DEFS/libgimpwidgets/gimpwidgets.def"; do
    name=${pair%%:*}; def=${pair#*:}
    dll="lib${name}-3.0-0.dll"          # how GIMP's Windows build names them
    imp="$WORK/winlibs/lib${name}-3.0.dll.a"
    [ -f "$def" ] || { echo "no export list for lib$name: $def" >&2; exit 1; }
    "$DLLTOOL" --dllname "$dll" --input-def "$def" --output-lib "$imp"
    LIBS_LINK+=("-l${name}-3.0")
done

echo "=== 4/5  compile + link"
CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-ignored-qualifiers -O2 -g -DWIN32 -I$DEFS"
IFS=. read -r PVMAJ PVMIN PVMIC <<<"$PLUGIN_VERSION"
"$WINDRES" --output-format=coff \
    --define PLUGIN_VERSION_MAJ=$PVMAJ --define PLUGIN_VERSION_MIN=$PVMIN \
    --define PLUGIN_VERSION_MICRO=$PVMIC \
    -I "$ROOT/win" -o "$WORK/winres/file-rom-bin.res" "$ROOT/win/file-rom-bin.rc"

for f in "$SRC"/*.c; do
    "$CC" -c "$f" -o "$WORK/obj/$(basename "${f%.c}").o" $CFLAGS $CFLAGS_DEP
done

"$CC" "$WORK"/obj/*.o "$WORK/winres/file-rom-bin.res" -o "$OUT" \
    -mwindows -L"$WORK/winlibs" "${LIBS_LINK[@]}" $LFLAGS_DEP

echo "=== 5/5  verify"
file "$OUT"
echo "--- imported DLLs ---"
"$OBJDUMP" -p "$OUT" | grep "DLL Name" | sort -u
echo
echo "Installed on Windows as:"
echo "  C:\\\\Program Files\\\\GIMP 3\\\\lib\\\\gimp\\\\3.0\\\\plug-ins\\\\file-rom-bin\\\\file-rom-bin.exe"
