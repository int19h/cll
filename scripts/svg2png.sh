#!/bin/bash
# Only the chapter 2 diagram still uses an SVG source.
set -euo pipefail
cd "$(dirname "$0")/.."
# librsvg uses fontconfig; Liberation Serif and Sans match the original fonts.
rsvg-convert --width 1200 --output assets/media/chapter-2-diagram.svg.png \
  orig/chapter-2-diagram.svg
