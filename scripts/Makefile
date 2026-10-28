chapters = $(if $(chapters), $(chapters), chapters/01.xml chapters/02.xml chapters/03.xml chapters/04.xml chapters/05.xml chapters/06.xml chapters/07.xml chapters/08.xml chapters/09.xml chapters/10.xml chapters/11.xml chapters/12.xml chapters/13.xml chapters/14.xml chapters/15.xml chapters/16.xml chapters/17.xml chapters/18.xml chapters/19.xml chapters/20.xml chapters/21.xml chapters/a01.xml)
builddir = $(if $(builddir), $(builddir), $(PWD)/build)
xsl_base = xml/docbook-xsl-1.78.1

SHELL=/bin/bash -o pipefail

.PHONY: all
all: xhtml_chapters xhtml_sections xhtml_nochunks pdf epub mobi

.PHONY: clean
clean:
	find $(PWD)/build/ $(PWD)/coverage/build/ $(builddir)/ -type d -name weasyprint-tools -prune -o \! -name 'jbovlaste*.xml' -type f -print0 | xargs -0 -r rm -f

.PHONY: realclean
realclean: clean
	find $(PWD)/build/ $(PWD)/coverage/build/ $(builddir)/ -type f | xargs -n 1 rm -f
	find $(PWD)/build/ $(PWD)/coverage/build/ $(builddir)/ -depth -type d -empty -exec rmdir {} \;

#*******
# Basic prep
#*******

.PHONY: build_metadata_force
$(builddir)/build-metadata: build_metadata_force
	@mkdir -p $(builddir)
	@{ scripts/build-version.sh && date +%Y-%m-%d; } >$@.tmp || { rm -f $@.tmp; exit 1; }
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

$(builddir)/cll.xml: $(chapters) xml/iso-pub.ent xml/identity.xsl xml/docbook2html_config_common.xsl scripts/update_jbovlaste_xml.sh scripts/generate_glossary.rb scripts/merge.sh .env $(builddir)/build-metadata
	regenerator --include-runtime $(PWD)/assets/scripts/sance-next.js > $(builddir)/sance.js
	rm -rf $(builddir)/xml $(builddir)/dtd
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
	rm -rf $(builddir)/xhtml_$*_chunks
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
	rm -rf $(copydir)/cll-xhtml_$*_chunks
	cp -pr $(builddir)/xhtml_$*_chunks $(copydir)/cll-xhtml_$*_chunks
	# The appcache is supremely unhelpful when testing
	find $(copydir) -name cll.appcache | xargs rm
endif

#*******
# ConTeXt PDF (opt-in; the default PDF and release targets still use Prince)
#*******
.PHONY: pdf_context
pdf_context: $(builddir)/cll-context.pdf
ifdef copydir
	mkdir -p "$(copydir)"
	cp "$(builddir)/cll-context.pdf" "$(copydir)/cll-context.pdf"
endif

$(builddir)/cll-context.pdf: $(builddir)/cll_processed_xhtml.xml scripts/docbook_to_context.rb scripts/build_context.sh scripts/context_assets.py assets/context/cll-layout.tex $(shell find assets/fonts assets/media -type f)
	bash scripts/build_context.sh "$(builddir)"

#*******
# Prince PDF
#*******
.PHONY: pdf
pdf: $(builddir)/pdf.done
$(builddir)/pdf.done: $(builddir)/cll_processed_xhtml.xml xml/docbook2html_config_prince.xsl assets/css/master.css scripts/xhtml_postprocess_cleanup.sh scripts/xhtml_postprocess_cleanup_file.rb scripts/xml_prince_postprocess.rb scripts/prince_check_margins.js scripts/prince_shave_index.js scripts/prince_check_index.js
	rm -rf $(builddir)/pdf
	mkdir -p $(builddir)/pdf
	cp -pr $(PWD)/assets/css/master.css $(builddir)/pdf/final.css
	
	cp -pr $(PWD)/assets $(builddir)/pdf/
	cp -pr $(PWD)/dtd $(builddir)/pdf/
	rm -rf $(builddir)/pdf/assets/scripts
	rm -rf $(builddir)/pdf/assets/media/examples
	rm -rf $(builddir)/pdf/assets/media/vreji
	
	xmlto -m xml/docbook2html_config_prince.xsl -o $(builddir)/pdf/ -x $(xsl_base)/xhtml/docbook.xsl xhtml-nochunks $(builddir)/cll_processed_xhtml.xml 2>&1 | grep -v 'No localization exists'
	scripts/xhtml_postprocess_cleanup.sh $(builddir)/pdf/
	ruby scripts/xml_prince_postprocess.rb $(builddir)/pdf/cll_processed_xhtml.html >$(builddir)/pdf/cll_processed_xhtml_pdf.html 2>$(builddir)/xml_prince_postprocess.out
	
	prince -vvv --script=scripts/prince_check_margins.js --script=scripts/prince_shave_index.js --script=scripts/prince_check_index.js $(builddir)/pdf/cll_processed_xhtml_pdf.html -o $(builddir)/cll.pdf
	touch $(builddir)/pdf.done
ifdef copydir
	mkdir -p $(copydir)
	cp $(builddir)/cll.pdf $(copydir)/cll.pdf
endif

#*******
# Optional WeasyPrint PDF, with static MathJax CommonHTML
#*******
WEASYPRINT_PYTHON = $(if $(CLL_WEASYPRINT_PYTHON),$(CLL_WEASYPRINT_PYTHON),$(builddir)/weasyprint-tools/venv/bin/python)
WEASYPRINT_ASSETS = $(wildcard assets/fonts/* assets/fonts/linux-libertine/* assets/media/*.png assets/media/*.gif assets/media/*.svg)
.PHONY: pdf_weasyprint
pdf_weasyprint: $(builddir)/cll-weasyprint.pdf
ifdef copydir
	mkdir -p $(copydir)
	cp $(builddir)/cll-weasyprint.pdf $(copydir)/cll-weasyprint.pdf
endif

$(builddir)/weasyprint/cll_processed_xhtml_pdf.html: $(builddir)/cll_processed_xhtml.xml xml/docbook2html_config_prince.xsl xml/docbook2html_config_common.xsl scripts/xml_prince_postprocess.rb scripts/xhtml_postprocess_cleanup.sh scripts/xhtml_postprocess_cleanup_file.rb assets/css/master.css $(WEASYPRINT_ASSETS)
	mkdir -p $(builddir)/weasyprint
	cp -pr $(PWD)/assets $(PWD)/dtd $(builddir)/weasyprint/
	cp assets/css/master.css $(builddir)/weasyprint/final.css
	xmlto -m xml/docbook2html_config_prince.xsl -o $(builddir)/weasyprint/ -x $(xsl_base)/xhtml/docbook.xsl xhtml-nochunks $(builddir)/cll_processed_xhtml.xml 2>&1 | grep -v 'No localization exists'
	scripts/xhtml_postprocess_cleanup.sh $(builddir)/weasyprint/
	ruby scripts/xml_prince_postprocess.rb $(builddir)/weasyprint/cll_processed_xhtml.html >$@.tmp
	mv $@.tmp $@

$(builddir)/cll-weasyprint.pdf: $(builddir)/weasyprint/cll_processed_xhtml_pdf.html assets/css/weasyprint.css scripts/weasyprint/render.py scripts/weasyprint/mathjax.cjs scripts/weasyprint/package-lock.json scripts/weasyprint/requirements.txt
	cp assets/css/weasyprint.css $(builddir)/weasyprint/weasyprint.css
	PYTHONDONTWRITEBYTECODE=1 CLL_MATHJAX_DIR="$${CLL_MATHJAX_DIR:-$(abspath $(builddir))/weasyprint-tools}" $(WEASYPRINT_PYTHON) scripts/weasyprint/render.py $< $@

#*******
# Typst PDF (optional; the default PDF target remains Prince)
#*******
.PHONY: pdf_typst typst
pdf_typst: $(builddir)/cll-typst.pdf
ifdef copydir
	mkdir -p "$(copydir)"
	cp "$(builddir)/cll-typst.pdf" "$(copydir)/cll-typst.pdf"
endif
typst: pdf_typst

$(builddir)/cll-typst.pdf: $(builddir)/cll_processed_xhtml.xml scripts/docbook_to_typst.rb scripts/build_pdf_typst.sh typst/book.typ $(wildcard assets/fonts/*.otf assets/fonts/linux-libertine/*.otf assets/media/*.png assets/media/*.gif assets/media/*.svg)
	TYPST_ALLOW_MISSING_REFS=$(if $(test),1,0) scripts/build_pdf_typst.sh "$(builddir)"

#*******
# EPUB ; also generates .MOBI
#*******
.PHONY: epub
.PHONY: mobi
mobi: $(builddir)/cll.epub
epub: $(builddir)/cll.epub

$(builddir)/cll.epub: $(builddir)/epub-xhtml/index.html scripts/build_epub.sh scripts/epub_branding.rb .env epub/mimetype epub/* epub/META-INF/container.xml
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
	rm -rf $(builddir)/epub-xhtml/
	mkdir -p $(builddir)/epub-xhtml/
	cp -pr $(PWD)/dtd $(builddir)/epub-xhtml/
	xmlto -m xml/docbook2html_config_epub.xsl -o $(builddir)/epub-xhtml/ -x $(xsl_base)/xhtml/chunk.xsl xhtml $(builddir)/cll_processed_xhtml.xml 2>&1 | grep -v 'No localization exists'
	cp -p $(PWD)/assets/css/master.css $(builddir)/epub-xhtml/final.css
	cp -pr $(PWD)/assets $(builddir)/epub-xhtml/
	rm -rf $(builddir)/epub-xhtml/assets/css
	rm -rf $(builddir)/epub-xhtml/assets/scripts
	rm -rf $(builddir)/epub-xhtml/assets/media/examples/
	rm -rf $(builddir)/epub-xhtml/assets/media/vreji/
	scripts/xhtml_postprocess_cleanup.sh $(builddir)/epub-xhtml/

#*******
# Testing
#*******
coverage: clean xhtml_nochunks pdf
ifneq ($(covcopydir),)
	mkdir -p $(covcopydir)
	cp $(builddir)/cll.pdf $(covcopydir)/cll.pdf
	rm -rf $(covcopydir)/cll-xhtml_no_chunks
	cp -pr $(builddir)/xhtml_no_chunks $(covcopydir)/cll-xhtml_no_chunks
	# The appcache is supremely unhelpful when testing
	find $(covcopydir) -name cll.appcache | xargs rm
endif
