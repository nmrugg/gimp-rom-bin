#!/usr/bin/env python3
"""
Fetch (and unpack) the MSYS2 mingw-w64 packages needed to cross build a
GIMP 3.x plug-in on Linux.

MSYS2 ships prebuilt Windows binaries of the whole GIMP dependency stack
(glib, gtk3, GEGL, babl, cairo, pango, ...).  Their packages are plain
.pkg.tar.zst files on a public mirror, so no package manager and no root
rights are needed - we just download and unpack them into a private
sysroot directory.

Usage:
    fetch-msys2-deps.py <sysroot-dir> <download-cache-dir> [pkg-config modules...]

Missing pkg-config requirements are resolved iteratively: pkg-config tells
us which module is missing, we guess the MSYS2 package that provides it and
fetch that too.
"""
import html
import os
import re
import subprocess
import sys

REPO_INDEX = {
    'x86_64': 'https://mirror.msys2.org/mingw/mingw64/',
    'i686':   'https://mirror.msys2.org/mingw/mingw32/',
}

# pkg-config module name -> MSYS2 package name, for the cases where the
# two differ (this is the only manual bookkeeping in the whole script).
PC_TO_PKG = {
    'epoxy': 'libepoxy', 'datrie': 'libdatrie', 'thai': 'libthai',
    'freetype2': 'freetype', 'libpng16': 'libpng', 'libpng': 'libpng',
    'liblzma': 'xz', 'Lerc': 'lerc', 'libbrotlidec': 'brotli',
    'libbrotlienc': 'brotli', 'libbrotlicommon': 'brotli',
    'libjpeg': 'libjpeg-turbo', 'icu-uc': 'icu', 'icu-i18n': 'icu',
    'gdk-pixbuf-2.0': 'gdk-pixbuf2', 'gmodule-no-export-2.0': 'glib2',
    'gmodule-2.0': 'glib2', 'gio-unix-2.0': 'glib2', 'intl': 'gettext-runtime',
    'pcre2-8': 'pcre2', 'harfbuzz-subset': 'harfbuzz', 'OpenEXR': 'openexr',
    'Imath': 'imath', 'Half': 'half', 'gio-win32-2.0': 'glib2',
    'gtk+-3.0': 'gtk3', 'gtk+-2.0': 'gtk2', 'gdk-3.0': 'gtk3', 'gdk-2.0': 'gtk2',
    'pangowin32': 'pango', 'pangoft2': 'pango', 'pangocairo': 'pango',
    'cairo-gobject': 'cairo', 'cairo-png': 'cairo', 'cairo-ft': 'cairo',
    'fontconfig': 'fontconfig', 'pixman-1': 'pixman',
}

# What a GIMP 3.x plug-in needs at build time (pkg-config modules).
DEFAULT_MODULES = ['gegl-0.4', 'babl-0.1', 'gtk+-3.0']


def index_packages(arch):
    """Return {package_name: (version_tuple, release, filename)} for a repo."""
    import urllib.request
    raw = urllib.request.urlopen(REPO_INDEX[arch], timeout=120).read().decode('utf-8', 'replace')
    prefix = 'mingw-w64-%s-' % arch
    out = {}
    for m in re.finditer(r'href="([^"]*' + re.escape(prefix) + r'[^"]+\.pkg\.tar\.zst)"', html.unescape(raw)):
        fn = os.path.basename(m.group(1))
        body = fn[len(prefix):-len('.pkg.tar.zst')]
        mm = re.match(r'(.+?)-([0-9][0-9a-zA-Z.+-]*)-([0-9]+)-(any|x86_64)$', body)
        if not mm:
            continue
        name, ver, rel, _suffix = mm.groups()
        key = tuple(int(x) if x.isdigit() else 0 for x in re.split(r'[.+-]', ver))
        if name not in out or (key, int(rel)) > out[name][:2]:
            out[name] = (key, int(rel), fn)
    return out


def candidates_for(pcname):
    # strip a trailing version component: gtk+-3.0 -> gtk+, glib-2.0 -> glib,
    # libpcre2-8 -> libpcre2
    base = re.sub(r'-(?:[0-9]+)(?:\.[0-9]+)*$', '', pcname)
    nobar = base.rstrip('+').replace('+', '')
    nolib = base[3:] if base.startswith('lib') else base

    tried = [PC_TO_PKG.get(pcname), PC_TO_PKG.get(base), PC_TO_PKG.get(nobar),
             base, nobar, 'lib' + nobar, nobar + '2', 'lib' + nobar + '2',
             nolib, 'lib' + nolib]
    seen, out = set(), []
    for t in tried:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def fetch_extract(pkgfile, cache, sysroot):
    dst = os.path.join(cache, pkgfile)
    if not os.path.exists(dst) or os.path.getsize(dst) == 0:
        tmp = dst + '.part'
        subprocess.run(['curl', '-sSL', '--fail', '-m', '600', '-o', tmp,
                        REPO_INDEX[pkgfile_arch] + pkgfile], check=True)
        os.replace(tmp, dst)
    subprocess.run(['tar', '--zstd', '-xf', dst, '-C', sysroot,
                    '--strip-components=1'], check=True)
    return os.path.getsize(dst)


def main():
    global pkgfile_arch
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    sysroot, cache = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    modules = sys.argv[3:] or DEFAULT_MODULES
    pkgfile_arch = os.environ.get('MSYS2_ARCH', 'x86_64')

    os.makedirs(sysroot, exist_ok=True)
    os.makedirs(cache, exist_ok=True)

    pkgs = index_packages(pkgfile_arch)
    env = dict(os.environ,
               PKG_CONFIG_PATH=os.path.join(sysroot, 'lib', 'pkgconfig'),
               PKG_CONFIG_LIBDIR=os.path.join(sysroot, 'lib', 'pkgconfig'))

    fetched = set()

    # modules given as "pkg:<name>" are MSYS2 package names to grab
    # unconditionally (Libs: entries in .pc files are not Requires:)
    forced = [m[4:] for m in modules if m.startswith('pkg:')]
    modules = [m for m in modules if not m.startswith('pkg:')]
    for pkg in forced:
        if pkg in pkgs and pkg not in fetched:
            size = fetch_extract(pkgs[pkg][2], cache, sysroot)
            print('  + %-26s <- %s (%d KB)' % ('(forced)', pkg, size // 1024))
            fetched.add(pkg)

    for _round in range(30):
        probe = subprocess.run(['pkg-config', '--cflags', '--libs'] + modules,
                               capture_output=True, text=True, env=env)
        if probe.returncode == 0:
            print('sysroot complete in %s (%d packages fetched)' % (sysroot, len(fetched)))
            return 0

        missing = set(re.findall(r"Package '?([\w+.-]+)'?,? (?:required by .* )?not found",
                                 probe.stderr))
        missing |= set(re.findall(r"Package ([\w+.-]+) was not found", probe.stderr))
        if not missing:
            print('pkg-config failed for another reason:\n' + probe.stderr[:800])
            return 1

        progressed = False
        for pc in sorted(missing):
            for cand in candidates_for(pc):
                if cand in pkgs and cand not in fetched:
                    fn = pkgs[cand][2]
                    size = fetch_extract(fn, cache, sysroot)
                    print('  + %-26s <- %s (%d KB)' % (pc, cand, size // 1024))
                    fetched.add(cand)
                    progressed = True
                    break
        if not progressed:
            print('stuck, still missing: %s' % ' '.join(sorted(missing)))
            print(probe.stderr[:600])
            return 1

    print('dependency resolution did not converge')
    return 1


if __name__ == '__main__':
    sys.exit(main())
