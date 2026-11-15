chapters = $(if $(chapters), $(chapters), chapters/01.xml chapters/02.xml chapters/03.xml chapters/04.xml chapters/05.xml chapters/06.xml chapters/07.xml chapters/08.xml chapters/09.xml chapters/10.xml chapters/11.xml chapters/12.xml chapters/13.xml chapters/14.xml chapters/15.xml chapters/16.xml chapters/17.xml chapters/18.xml chapters/19.xml chapters/20.xml chapters/21.xml chapters/a01.xml)
ifeq ($(origin builddir),undefined)
builddir := $(PWD)/build
endif
xsl_base = xml/docbook-xsl-1.78.1
safe_rm = scripts/safe-rm-tree.sh

# Folder variables reach recursive deletes, so check them at parse time,
# before any recipe runs (issue #271). Every folder is resolved through
# symbolic links first (realpath of the parent plus the final component,
# like the helper). /, the home folder, the checkout and every parent of
# the checkout are always refused. A folder outside the checkout's build
# folders (build or coverage/build, after resolving their links, so a
# build link to a separate folder still works) needs
# ALLOW_OUTSIDE_BUILDDIR=yes; cll_build sets it when -a or -A names an
# archive folder. An empty copydir or covcopydir means "no archive
# folder", as before. The helper repeats the checks at delete time.
override _checkout_res := $(realpath $(CURDIR))
override _home_res := $(if $(realpath $(HOME)),$(realpath $(HOME)),$(HOME))
override _resolve = $(if $(realpath $(1)),$(realpath $(1)),$(patsubst %/,%,$(realpath $(dir $(patsubst %/,%,$(1)))))/$(notdir $(patsubst %/,%,$(1))))
override _build_res := $(call _resolve,$(_checkout_res)/build)
override _covbuild_res := $(call _resolve,$(_checkout_res)/coverage/build)
override _inside_build = $(filter $(_build_res) $(_build_res)/% $(_covbuild_res) $(_covbuild_res)/%,$(1))
override _forbidden = $(if $(filter / $(_home_res),$(1)),yes,$(if $(filter $(1) $(1)/%,$(_checkout_res)),yes,))
override _reject_badname = $(if $(filter 1,$(words $(2))),,$(error $(1) must resolve to exactly one folder, not "$(2)"))$(if $(findstring ',$(2)),$(error $(1) must not contain a single quote: $(2)),)
$(call _reject_badname,the checkout,$(_checkout_res))
ifneq ($(strip $(HOME)),)
$(call _reject_badname,the home folder,$(_home_res))
endif
$(call _reject_badname,the build folder,$(_build_res))
$(call _reject_badname,the coverage build folder,$(_covbuild_res))
ifneq ($(words $(CURDIR)),1)
$(error the checkout path must not contain spaces: $(CURDIR))
endif
ifneq ($(strip $(HOME)),)
ifneq ($(words $(HOME)),1)
$(error the home folder path must not contain spaces: $(HOME))
endif
endif

# The two folders clean always traverses: a link to a separate build
# folder is fine, a link into the source tree is not.
ifneq ($(call _forbidden,$(_build_res)),)
$(error the build folder resolves to a refused folder: $(_build_res))
endif
ifeq ($(filter $(_checkout_res)/%,$(_build_res))x,$(_build_res)x)
ifneq ($(_build_res),$(_checkout_res)/build)
$(error the build folder link points into the source tree: $(_build_res))
endif
endif
ifneq ($(call _forbidden,$(_covbuild_res)),)
$(error the coverage build folder resolves to a refused folder: $(_covbuild_res))
endif
ifeq ($(filter $(_checkout_res)/%,$(_covbuild_res))x,$(_covbuild_res)x)
ifneq ($(_covbuild_res),$(_checkout_res)/coverage/build)
$(error the coverage build folder link points into the source tree: $(_covbuild_res))
endif
endif

ifeq ($(strip $(builddir)),)
$(error builddir must not be empty)
endif
ifneq ($(words $(builddir)),1)
$(error builddir must be one folder: $(builddir))
endif
override _builddir_res := $(call _resolve,$(builddir))
$(call _reject_badname,builddir,$(_builddir_res))
ifneq ($(words $(_builddir_res)),1)
$(error builddir does not resolve to one folder: $(builddir))
endif
ifneq ($(call _forbidden,$(_builddir_res)),)
$(error builddir must not be /, the home folder, the checkout, or a parent of the checkout: $(builddir))
endif
ifeq ($(call _inside_build,$(_builddir_res)),)
ifneq ($(ALLOW_OUTSIDE_BUILDDIR),yes)
$(error builddir is outside the checkout build folders: $(builddir); set ALLOW_OUTSIDE_BUILDDIR=yes to allow it)
endif
endif
ifneq ($(strip $(copydir)),)
ifneq ($(words $(copydir)),1)
$(error copydir must be one folder: $(copydir))
endif
override _copydir_res := $(call _resolve,$(copydir))
$(call _reject_badname,copydir,$(_copydir_res))
ifneq ($(words $(_copydir_res)),1)
$(error copydir does not resolve to one folder: $(copydir))
endif
ifneq ($(call _forbidden,$(_copydir_res)),)
$(error copydir must not be /, the home folder, the checkout, or a parent of the checkout: $(copydir))
endif
ifeq ($(call _inside_build,$(_copydir_res)),)
ifneq ($(ALLOW_OUTSIDE_BUILDDIR),yes)
$(error copydir is outside the checkout build folders: $(copydir); set ALLOW_OUTSIDE_BUILDDIR=yes to allow it)
endif
endif
endif
ifneq ($(strip $(covcopydir)),)
ifneq ($(words $(covcopydir)),1)
$(error covcopydir must be one folder: $(covcopydir))
endif
override _covcopydir_res := $(call _resolve,$(covcopydir))
$(call _reject_badname,covcopydir,$(_covcopydir_res))
ifneq ($(words $(_covcopydir_res)),1)
$(error covcopydir does not resolve to one folder: $(covcopydir))
endif
ifneq ($(call _forbidden,$(_covcopydir_res)),)
$(error covcopydir must not be /, the home folder, the checkout, or a parent of the checkout: $(covcopydir))
endif
ifeq ($(call _inside_build,$(_covcopydir_res)),)
ifneq ($(ALLOW_OUTSIDE_BUILDDIR),yes)
$(error covcopydir is outside the checkout build folders: $(covcopydir); set ALLOW_OUTSIDE_BUILDDIR=yes to allow it)
endif
endif
endif

SHELL=/bin/bash -o pipefail

.PHONY: all
all: xhtml_chapters xhtml_sections xhtml_nochunks pdf epub mobi

.PHONY: clean
clean:
	# Walk only the resolved, checked folders. No -L, and names move
	# through -print0, so a file name with a space cannot split into
	# another path.
	for d in '$(_build_res)' '$(_covbuild_res)' '$(_builddir_res)'; do if [ -d "$$d" ]; then find "$$d" \! -name 'jbovlaste*.xml' -type f -print0 | xargs -0 -r rm -f --; fi; done

.PHONY: realclean
realclean: clean
	for d in '$(_build_res)' '$(_covbuild_res)' '$(_builddir_res)'; do if [ -d "$$d" ]; then find "$$d" -type f -print0 | xargs -0 -r rm -f --; fi; done
	for d in '$(_build_res)' '$(_covbuild_res)' '$(_builddir_res)'; do if [ -d "$$d" ]; then find "$$d" -depth -mindepth 1 -type d -empty -print0 | xargs -0 -r rmdir --; fi; done

#*******
# Basic prep
#*******

$(builddir)/cll.xml: $(chapters) xml/iso-pub.ent xml/identity.xsl xml/docbook2html_config_common.xsl scripts/update_jbovlaste_xml.sh scripts/generate_glossary.rb scripts/merge.sh
	regenerator --include-runtime $(PWD)/assets/scripts/sance-next.js > $(builddir)/sance.js
	mkdir -p $(builddir)
	$(safe_rm) --root "$(builddir)" "$(builddir)/xml" "$(builddir)/dtd"
	cp -pr $(PWD)/xml $(builddir)/
	cp -pr $(PWD)/dtd $(builddir)/
	scripts/merge.sh -b "$(builddir)" $(test) $(chapters)

$(builddir)/cll_processed_xhtml.xml: $(builddir)/cll.xml scripts/xml_preprocess.rb
	ruby scripts/xml_preprocess.rb $(builddir)/cll.xml >$(builddir)/cll_processed_xhtml.xml 2>$(builddir)/xml_preprocess.out || (tail $(builddir)/xml_preprocess.out && false)

#*******
# XHTML, with various chunk sizes
#*******
# Name the various chunking targets
.PHONY: xhtml_chapters xhtml_sections xhtml_nochunks
xhtml_chapters: $(builddir)/xhtml_chapter_chunks.done
xhtml_chapters: xsl_file = $(xsl_base)/xhtml/chunk.xsl

xhtml_sections: $(builddir)/xhtml_section_chunks.done
xhtml_sections: xsl_file = $(xsl_base)/xhtml/chunk.xsl

xhtml_nochunks: nochunks = -nochunks
xhtml_nochunks: xsl_file = $(xsl_base)/xhtml/docbook.xsl
xhtml_nochunks: $(builddir)/xhtml_no_chunks.done

# Do the actual chunking work
$(builddir)/xhtml_%_chunks.done: xml/docbook2html_config_%_chunks.xsl $(builddir)/cll_processed_xhtml.xml xml/docbook2html_config_xhtml.xsl assets/css/master.css scripts/xhtml_postprocess_appcache.sh scripts/xhtml_postprocess_cleanup.sh scripts/xhtml_postprocess_cleanup_file.rb
	mkdir -p $(builddir)
	$(safe_rm) --root "$(builddir)" "$(builddir)/xhtml_$*_chunks"
	mkdir -p $(builddir)/xhtml_$*_chunks
	cp -pr $(PWD)/dtd $(builddir)/xhtml_$*_chunks/
	xmlto -m xml/docbook2html_config_$*_chunks.xsl -x $(xsl_file) -o $(builddir)/xhtml_$*_chunks/ xhtml$(nochunks) $(builddir)/cll_processed_xhtml.xml 2>&1 | grep -v 'No localization exists'
	# We run tidy on the no-chunk version, because it's all in
	# one place so it's easy
	test -f $(builddir)/xhtml_$*_chunks/index.html || cat $(builddir)/xhtml_$*_chunks/cll_processed_xhtml.html | scripts/tidy -e - 2>&1 | grep -v '<table> lacks "summary" attribute'
# Handle the no-chunk case; can't figure out how to set the
# name of the output file, so move it to index.html
	test -f $(builddir)/xhtml_$*_chunks/index.html || mv $(builddir)/xhtml_$*_chunks/cll_processed_xhtml.html $(builddir)/xhtml_$*_chunks/index.html
	cp $(PWD)/assets/css/master.css $(builddir)/xhtml_$*_chunks/final.css
	cp -pr $(PWD)/assets $(builddir)/xhtml_$*_chunks/
	cp -avr $(builddir)/sance.js $(builddir)/xhtml_$*_chunks/assets/scripts/sance.js
	scripts/xhtml_postprocess_cleanup.sh $(builddir)/xhtml_$*_chunks/
	scripts/xhtml_postprocess_appcache.sh $(builddir)/xhtml_$*_chunks/
	touch $(builddir)/xhtml_$*_chunks.done

ifdef copydir
	mkdir -p $(copydir)
	$(safe_rm) --root "$(copydir)" "$(copydir)/cll-xhtml_$*_chunks"
	cp -pr $(builddir)/xhtml_$*_chunks $(copydir)/cll-xhtml_$*_chunks
	# The appcache is supremely unhelpful when testing
	find $(copydir) -name cll.appcache | xargs rm
endif

#*******
# Prince PDF
#*******
.PHONY: pdf
pdf: $(builddir)/pdf.done
$(builddir)/pdf.done: $(builddir)/cll_processed_xhtml.xml xml/docbook2html_config_prince.xsl assets/css/master.css scripts/xhtml_postprocess_cleanup.sh scripts/xhtml_postprocess_cleanup_file.rb
	mkdir -p $(builddir)
	$(safe_rm) --root "$(builddir)" "$(builddir)/pdf"
	mkdir -p $(builddir)/pdf
	cp -pr $(PWD)/assets/css/master.css $(builddir)/pdf/final.css
	
	cp -pr $(PWD)/assets $(builddir)/pdf/
	cp -pr $(PWD)/dtd $(builddir)/pdf/
	$(safe_rm) --root "$(builddir)/pdf/assets" "$(builddir)/pdf/assets/scripts" "$(builddir)/pdf/assets/media/examples" "$(builddir)/pdf/assets/media/vreji"
	
	xmlto -m xml/docbook2html_config_prince.xsl -o $(builddir)/pdf/ -x $(xsl_base)/xhtml/docbook.xsl xhtml-nochunks $(builddir)/cll_processed_xhtml.xml 2>&1 | grep -v 'No localization exists'
	scripts/xhtml_postprocess_cleanup.sh $(builddir)/pdf/
	ruby scripts/xml_prince_postprocess.rb $(builddir)/pdf/cll_processed_xhtml.html >$(builddir)/pdf/cll_processed_xhtml_pdf.html 2>$(builddir)/xml_prince_postprocess.out
	
	prince -vvv --script=scripts/prince_check_margins.js --script=scripts/prince_shave_index.js $(builddir)/pdf/cll_processed_xhtml_pdf.html -o $(builddir)/cll.pdf
	touch $(builddir)/pdf.done
ifdef copydir
	mkdir -p $(copydir)
	cp $(builddir)/cll.pdf $(copydir)/cll.pdf
endif

#*******
# EPUB ; also generates .MOBI
#*******
.PHONY: epub
.PHONY: mobi
mobi: $(builddir)/cll.epub
epub: $(builddir)/cll.epub

$(builddir)/cll.epub: $(builddir)/epub-xhtml/index.html scripts/build_epub.sh epub/mimetype epub/* epub/META-INF/container.xml
	scripts/build_epub.sh $(PWD)
	mv $(builddir)/cll.epub $(builddir)/cll.tmp.epub
	java -jar $(PWD)/epub/epubcheck-4.0.1/epubcheck.jar $(builddir)/cll.tmp.epub 2>&1 | grep -v "should have the extension '.xhtml'"
# This both checks for Kindle support *and* generates the .mobi
	# $(PWD)/epub/kindlegen/kindlegen $(builddir)/cll.tmp.epub -o cll.mobi
# It checks out; move it into place
	mv $(builddir)/cll.tmp.epub $(builddir)/cll.epub
ifdef copydir
	mkdir -p $(copydir)
	cp $(builddir)/cll.epub $(copydir)/cll.epub
	cp $(builddir)/cll.mobi $(copydir)/cll.mobi
endif

# Note that the epub doesn't rely on the PDF, but rather on the HTML
# that is used to build the PDF, but it amounts to the same thing
# for requirements here.
$(builddir)/epub-xhtml/index.html: $(builddir)/cll_processed_xhtml.xml xml/docbook2html_config_common.xsl xml/docbook2html_config_epub.xsl $(PWD)/assets/css/master.css $(PWD)/assets/media/* scripts/xhtml_postprocess_cleanup.sh scripts/xhtml_postprocess_cleanup_file.rb
	mkdir -p $(builddir)
	$(safe_rm) --root "$(builddir)" "$(builddir)/epub-xhtml"
	mkdir -p $(builddir)/epub-xhtml/
	cp -pr $(PWD)/dtd $(builddir)/epub-xhtml/
	xmlto -m xml/docbook2html_config_epub.xsl -o $(builddir)/epub-xhtml/ -x $(xsl_base)/xhtml/chunk.xsl xhtml $(builddir)/cll_processed_xhtml.xml 2>&1 | grep -v 'No localization exists'
	mv $(PWD)/assets/css/master.css $(builddir)/epub-xhtml/final.css	
	cp -pr $(PWD)/assets $(builddir)/epub-xhtml/
	$(safe_rm) --root "$(builddir)/epub-xhtml/assets" "$(builddir)/epub-xhtml/assets/scripts" "$(builddir)/epub-xhtml/assets/media/examples" "$(builddir)/epub-xhtml/assets/media/vreji"
	scripts/xhtml_postprocess_cleanup.sh $(builddir)/epub-xhtml/

#*******
# Testing
#*******
coverage: clean xhtml_nochunks pdf
ifneq ($(covcopydir),)
	mkdir -p $(covcopydir)
	cp $(builddir)/cll.pdf $(covcopydir)/cll.pdf
	$(safe_rm) --root "$(covcopydir)" "$(covcopydir)/cll-xhtml_no_chunks"
	cp -pr $(builddir)/xhtml_no_chunks $(covcopydir)/cll-xhtml_no_chunks
	# The appcache is supremely unhelpful when testing
	find $(covcopydir) -name cll.appcache | xargs rm
endif
