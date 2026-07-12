# Building natively (outside the container)

The supported build environment is the container (`Dockerfile`,
`run_container.sh`); use it when you can. This note lists the minimal
native prerequisites for running `./cll_build` directly, for cases
where the container is impractical (quick single-chapter tests,
debugging a build step).

`cll_build` propagates failures: if any internal `make` step fails
(including a missing tool), the wrapper exits nonzero and prints
`BUILD FAILED`. The post-build diff against `official/` is skipped on
failure.

## Tools the build invokes

Debian/Ubuntu package names in parentheses where they differ.

- **Always**: `bash`, `make`, `wget`, `unzip`, `xmlto` (pulls in
  `xsltproc`), `ruby` with the gems in `Gemfile` (`ruby-full`, then
  `gem install bundler && bundle install`), and the DejaVu, Linux
  Libertine, and GNU Unifont fonts (`fonts-dejavu`,
  `fonts-linuxlibertine`, `unifont`). The DocBook XSL stylesheets are
  downloaded and unpacked automatically on first run.
- **XHTML targets**: `regenerator` from npm (`npm install -g
  regenerator`) for the ES5 transform of `assets/scripts/sance-next.js`.
- **PDF target**: `prince` (PrinceXML; download a package for your
  platform from princexml.com).
- **EPUB target**: `ebook-convert` from Calibre, plus a Java runtime
  (`default-jre`) for epubcheck.

A single-chapter test build that exercises most of the toolchain:

```
./cll_build -t chapters/05.xml
```

If a tool above is missing, the affected target fails and so does
`cll_build`; targets whose tools are present can still be built
individually via `-T <target>` (see `./cll_build -h` for the list).
