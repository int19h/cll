#!/usr/bin/env bash
# Compile the engine shipped with the fixed ConTeXt source distribution.
set -euo pipefail
root=${1:?Usage: scripts/install-context.sh INSTALL_DIRECTORY [ARCHIVE_DIRECTORY]}
archives=${2:-$(mktemp -d)}
context_commit=5751e39641a5acae5ce3eb579386394a1ed5da07
fonts_commit=3b96e7c03fd4d68e5339e580ab87bdd9721c24f2
context_sha256=824257b46edc81c5d2b5cfb07959da9ebd247861ba4e0f526a8c922896a2849a
fonts_sha256=215724de72cb418c4ef50df94188040cd3d19c958f257f23fa839204cbde4a40
version='2026.10.25 20:06'
case $(uname -m) in
  x86_64) platform=linux-64 ;;
  aarch64) platform=linux-aarch64 ;;
  *) echo 'ConTeXt supports only x86_64 and aarch64 in this image.' >&2; exit 1 ;;
esac
mkdir -p "$archives" "$root/tex/texmf-context" "$root/tex/texmf" "$root/tex/texmf-$platform/bin"
fetch() {
  local url=$1 file=$2 expected=$3
  if [ ! -f "$file" ]; then
    curl --fail --location --retry 3 "$url" --output "$file.tmp"
    mv "$file.tmp" "$file"
  fi
  echo "$expected  $file" | sha256sum -c -
}
fetch "https://codeload.github.com/contextgarden/context/tar.gz/$context_commit" \
  "$archives/context-source.tar.gz" "$context_sha256"
fetch "https://codeload.github.com/contextgarden/context-distribution-fonts/tar.gz/$fonts_commit" \
  "$archives/context-fonts.tar.gz" "$fonts_sha256"
# No upstream installer runs. These are the only two downloaded inputs.
tar -xzf "$archives/context-source.tar.gz" --strip-components=1 -C "$root/tex/texmf-context"
tar -xzf "$archives/context-fonts.tar.gz" --strip-components=1 -C "$root/tex/texmf"
# The source tree supplies contextcnf.lua. Select it explicitly for the resolver.
ln -s contextcnf.lua "$root/tex/texmf-context/web2c/texmfcnf.lua"
grep -F "\\edef\\contextversion{$version}" "$root/tex/texmf-context/tex/context/base/mkiv/context.mkiv"
compiler_build=$(mktemp -d)
cmake -S "$root/tex/texmf-context/source/luametatex" -B "$compiler_build" \
  -DCMAKE_BUILD_TYPE=Release -DLMT_NOOPTIMIZE=ON
cmake --build "$compiler_build" --parallel 4
bin="$root/tex/texmf-$platform/bin"
install -m 755 "$compiler_build/luametatex" "$bin/luametatex"
for name in mtxrun context; do
  ln -s luametatex "$bin/$name"
  cp "$root/tex/texmf-context/scripts/context/lua/$name.lua" "$bin/"
  cp "$root/tex/texmf-context/scripts/context/lua/$name.lmt" "$bin/"
done
ln -s "$bin" "$root/platform-bin"
export PATH="$bin:$PATH"
mtxrun --generate
context --make en
context --version | grep -F "current version: $version"
mkdir -p /usr/local/share/cll
printf '%s\n' "ConTeXt $version" "context $context_commit $context_sha256" \
  "fonts $fonts_commit $fonts_sha256" > /usr/local/share/cll/context-sources.txt
rm -rf "$compiler_build"
if [ "$#" -lt 2 ]; then
  rm -rf "$archives"
fi
