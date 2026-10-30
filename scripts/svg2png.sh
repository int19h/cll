#!/bin/bash
# Only the chapter 2 diagram still uses an SVG source.
set -euo pipefail
cd "$(dirname "$0")/.."
svgexport orig/chapter-2-diagram.svg orig/chapter-2-diagram.svg.png 400:
