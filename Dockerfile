FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS build-base

# Modern build environment for the book (replaces the old Fedora 30 /
# Ruby 2.6 / Prince 12.5 image). The DocBook XSL stylesheets that drive
# the layout are pinned in-tree (xml/docbook-xsl-1.78.1.zip). The
# output also depends on xsltproc/libxslt, Ruby, xmllint, and fonts.
# Fix the base image and signed APT archive below. Prince and EPUBCheck are pinned separately.
ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8

# Core toolchain:
#  - xmlto pulls in xsltproc and libxml2-utils (xmllint)
#  - ruby + build deps for native gems (nokogiri)
#  - nodejs/npm for regenerator and the diff tooling
#  - zip/unzip, wget, git, make
#  - fonts + default-jre are for the PDF and EPUB targets
# Bootstrap HTTPS before APT installs the snapshot's ca-certificates package.
ADD https://curl.se/ca/cacert-2026-11-05.pem /etc/ssl/certs/ca-certificates.crt
RUN chmod 644 /etc/ssl/certs/ca-certificates.crt \
    && echo '427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285  /etc/ssl/certs/ca-certificates.crt' | sha256sum -c - \
    && printf '%s\n' 'Types: deb' \
      'URIs: https://snapshot.ubuntu.com/ubuntu/20261117T000000Z/' \
      'Suites: resolute resolute-updates resolute-security' 'Components: main universe' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      'Check-Valid-Until: no' > /etc/apt/sources.list.d/ubuntu.sources \
    && printf '%s\n' 'Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";' > /etc/apt/apt.conf.d/99-snapshot-ca
RUN apt-get update -o APT::Update::Error-Mode=any && apt-get install -y --no-install-recommends \
      make bash wget curl git ca-certificates locales \
      xmlto xsltproc libxml2-utils zip unzip \
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
COPY scripts/weasyprint/package.json scripts/weasyprint/package-lock.json /opt/cll-mathjax/
RUN npm ci --prefix /opt/cll-mathjax --ignore-scripts --no-audit --no-fund
ENV CLL_MATHJAX_DIR=/opt/cll-mathjax

WORKDIR /srv/cll

# Optional native PDF image. The default final stage still installs Prince.
FROM build-base AS typst
COPY scripts/install_typst.sh /usr/local/src/install_typst.sh
COPY scripts/safe-rm-tree.sh /usr/local/src/safe-rm-tree.sh
RUN bash /usr/local/src/install_typst.sh /usr/local/bin

FROM build-base AS prince
# Prince XML (PDF target). Arch-aware Ubuntu 26.04 build.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
      amd64) prince_sha256=40b31c21895956a277c2849b7609a377c5fae5c3554c8c0a712e71535633fd68 ;; \
      arm64) prince_sha256=763d632da24e3b63fa1119c5e1f3be70aa13e96a50e1fd92168aeb9f143d67be ;; \
      *) exit 1 ;; \
    esac \
    && cd /usr/src \
    && wget -q "https://www.princexml.com/download/prince_16.2-1_ubuntu26.04_${arch}.deb" \
    && echo "$prince_sha256  prince_16.2-1_ubuntu26.04_${arch}.deb" | sha256sum -c - \
    && apt-get update -o APT::Update::Error-Mode=any \
    && apt-get install -y ./prince_16.2-1_ubuntu26.04_${arch}.deb \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f "prince_16.2-1_ubuntu26.04_${arch}.deb" \
    && prince --version

# EPUBCheck 5.4.0. scripts/install-epubcheck.sh pins the official archive and its SHA-256.
# Ubuntu 26.04 default-jre-headless (Java 25) runs this release.
COPY scripts/install-epubcheck.sh /usr/local/src/install-epubcheck.sh
COPY scripts/safe-rm-tree.sh /usr/local/src/safe-rm-tree.sh
RUN bash /usr/local/src/install-epubcheck.sh /usr/local/share/epubcheck
ENV EPUBCHECK_JAR=/usr/local/share/epubcheck/epubcheck.jar

# Nu Html Checker. scripts/install-vnu.sh pins the vnu-jar package and its SHA-256.
COPY scripts/install-vnu.sh /usr/local/src/install-vnu.sh
COPY scripts/safe-rm-tree.sh /usr/local/src/safe-rm-tree.sh
RUN bash /usr/local/src/install-vnu.sh /usr/local/share/vnu
ENV VNU_JAR=/usr/local/share/vnu/vnu.jar

WORKDIR /srv/cll
