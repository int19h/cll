FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS build-base

# Modern build environment for the book (replaces the old Fedora 30 /
# Ruby 2.6 / Prince 12.5 image). The DocBook XSL stylesheets that drive
# the layout are pinned in-tree (xml/docbook-xsl-1.78.1.zip). The
# output also depends on xsltproc/libxslt, Ruby, xmllint, and fonts.
# Fix the base image and signed APT archive below. Prince is pinned separately.
ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8

# Core toolchain:
#  - xmlto pulls in xsltproc and libxml2-utils (xmllint)
#  - ruby + build deps for native gems (nokogiri)
#  - nodejs/npm for regenerator and the diff tooling
#  - tidy, zip/unzip, wget, git, make
#  - fonts + default-jre are for the PDF and EPUB targets
# Bootstrap HTTPS before APT installs the snapshot's ca-certificates package.
ADD https://curl.se/ca/cacert-2026-10-20.pem /etc/ssl/certs/ca-certificates.crt
RUN chmod 644 /etc/ssl/certs/ca-certificates.crt \
    && echo '796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe  /etc/ssl/certs/ca-certificates.crt' | sha256sum -c - \
    && printf '%s\n' 'Types: deb' \
      'URIs: https://snapshot.ubuntu.com/ubuntu/20261027T000000Z/' \
      'Suites: noble noble-updates noble-security' 'Components: main universe' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      'Check-Valid-Until: no' > /etc/apt/sources.list.d/ubuntu.sources
RUN apt-get update -o APT::Update::Error-Mode=any && apt-get install -y --no-install-recommends \
      make bash wget curl git ca-certificates locales \
      xmlto xsltproc libxml2-utils tidy zip unzip \
      ruby ruby-dev build-essential pkg-config \
      libxml2-dev libxslt1-dev zlib1g-dev \
      nodejs npm \
      default-jre-headless \
      fonts-dejavu fontconfig fonts-dejavu-core fonts-linuxlibertine \
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

WORKDIR /srv/cll

# Optional native PDF image. The default final stage still installs Prince.
FROM build-base AS typst
COPY scripts/install_typst.sh /usr/local/src/install_typst.sh
RUN bash /usr/local/src/install_typst.sh /usr/local/bin

FROM build-base AS prince
# Prince XML (PDF target). Arch-aware Ubuntu 24.04 build.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
      amd64) prince_sha256=305d755ff6437e855c151920d1363970d8cc7bff1ea4006290c36ad5d8e06c69 ;; \
      arm64) prince_sha256=c8f411c0a06fef8522ae17cdcabfb1992379f017dcd213812154ca6e3cb762bc ;; \
      *) exit 1 ;; \
    esac \
    && cd /usr/src \
    && wget -q "https://www.princexml.com/download/prince_16.2-1_ubuntu24.04_${arch}.deb" \
    && echo "$prince_sha256  prince_16.2-1_ubuntu24.04_${arch}.deb" | sha256sum -c - \
    && apt-get update -o APT::Update::Error-Mode=any \
    && apt-get install -y ./prince_16.2-1_ubuntu24.04_${arch}.deb \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f "prince_16.2-1_ubuntu24.04_${arch}.deb" \
    && prince --version

WORKDIR /srv/cll
