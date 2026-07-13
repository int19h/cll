FROM ubuntu:24.04

# Modern build environment for the book (replaces the old Fedora 30 /
# Ruby 2.6 / Prince 12.5 image). The DocBook XSL stylesheets that drive
# the layout are pinned in-tree (xml/docbook-xsl-1.78.1.zip), so the
# structure/layout of the output does not depend on the OS here; the
# actual bytes still pass through xsltproc/libxslt, the Ruby cleanup, and
# xmllint, so the pinned gem/tool versions below matter for stable
# output. Prince (PDF only) is versioned separately.
ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8

# Core toolchain:
#  - xmlto pulls in xsltproc and libxml2-utils (xmllint)
#  - ruby + build deps for native gems (nokogiri)
#  - nodejs/npm for regenerator and the diff tooling
#  - tidy, zip/unzip, wget, git, make
#  - fonts + default-jre are for the PDF and EPUB targets
RUN apt-get update && apt-get install -y --no-install-recommends \
      make bash wget curl git ca-certificates locales \
      xmlto xsltproc libxml2-utils tidy zip unzip \
      ruby ruby-dev build-essential pkg-config \
      libxml2-dev libxslt1-dev zlib1g-dev \
      nodejs npm \
      default-jre-headless \
      fonts-dejavu fonts-dejavu-core fonts-linuxlibertine \
    && rm -rf /var/lib/apt/lists/*

# The build scripts hardcode the en_US.UTF-8 locale (glossary collation).
# The current tree's scripts use #!/bin/bash, but HISTORICAL build trees
# (older refs built by diff_upstream / the pages workflow) still have
# #!/bin/sh scripts with bash arrays/here-strings that dash rejects; on
# the old Fedora image /bin/sh was bash, so reproduce that here to build
# those trees unchanged.
RUN locale-gen en_US.UTF-8 && ln -sf /bin/bash /bin/sh

# Ruby gems the build scripts require (nokogiri, optimist, htmlentities).
# Pinned to known-good versions for reproducible builds; nokogiri ships
# precompiled native gems for x86_64-linux and aarch64-linux, so no
# compilation (or -dev headers) is needed. Installed globally because the
# Makefile invokes `ruby scripts/*.rb` directly, not via bundler.
RUN gem install --no-document nokogiri:1.18.8 optimist:3.2.0 htmlentities:4.3.4

# Node tools: regenerator transpiles assets/scripts/sance-next.js during
# the cll.xml assembly step. Pinned since it emits build/sance.js.
RUN npm config set fetch-retries 5 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm i -g regenerator@0.14.12 --unsafe-perm=true

# Prince XML (PDF target). Arch-aware Ubuntu 24.04 build.
RUN arch="$(dpkg --print-architecture)" \
    && cd /usr/src \
    && wget -q "https://www.princexml.com/download/prince_16.2-1_ubuntu24.04_${arch}.deb" \
    && (apt-get update && apt-get install -y ./prince_16.2-1_ubuntu24.04_${arch}.deb; rm -rf /var/lib/apt/lists/*) \
    && rm -f "prince_16.2-1_ubuntu24.04_${arch}.deb" \
    && prince --version

WORKDIR /srv/cll
