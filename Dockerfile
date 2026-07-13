FROM ubuntu:24.04

# Modern build environment for the book (replaces the old Fedora 30 /
# Ruby 2.6 / Prince 12.5 image). The DocBook XSL stylesheets are pinned
# in-tree (xml/docbook-xsl-1.78.1.zip) and drive the HTML/PDF layout, so
# HTML output is stable regardless of the OS/toolchain version here;
# only the Prince version affects PDF rendering.
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

# The build scripts hardcode the en_US.UTF-8 locale (glossary collation),
# and several #!/bin/sh scripts (e.g. scripts/merge.sh) use bash arrays
# and here-strings that dash rejects. On the old Fedora image /bin/sh was
# bash; reproduce both so historical build trees build unchanged.
RUN locale-gen en_US.UTF-8 && ln -sf /bin/bash /bin/sh

# Ruby gems the build scripts require (loose constraints in Gemfile;
# current versions satisfy them). Installed globally because the
# Makefile invokes `ruby scripts/*.rb` directly, not via bundler.
RUN gem install --no-document nokogiri optimist htmlentities

# Node tools: regenerator transpiles assets/scripts/sance-next.js during
# the cll.xml assembly step.
RUN npm i -g regenerator --unsafe-perm=true

# Prince XML (PDF target). Arch-aware Ubuntu 24.04 build.
RUN arch="$(dpkg --print-architecture)" \
    && cd /usr/src \
    && wget -q "https://www.princexml.com/download/prince_16.2-1_ubuntu24.04_${arch}.deb" \
    && (apt-get update && apt-get install -y ./prince_16.2-1_ubuntu24.04_${arch}.deb; rm -rf /var/lib/apt/lists/*) \
    && rm -f "prince_16.2-1_ubuntu24.04_${arch}.deb" \
    && prince --version

WORKDIR /srv/cll
