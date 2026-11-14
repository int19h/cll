#!/usr/bin/env python3
"""The ePub stylesheets write the navigation document from the DocBook source.

Issue #208. Needs xsltproc, Ruby, and Nokogiri. It does not build the book.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

SOURCE = Path(__file__).resolve().parent.parent
XHTML = '{http://www.w3.org/1999/xhtml}'
XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'
LISTS = {XHTML + 'dl', XHTML + 'ul', XHTML + 'ol'}

BOOK = '''<?xml version="1.0" encoding="UTF-8"?>
<book xmlns="http://docbook.org/ns/docbook" version="5.0" xml:lang="en">
  <info><title>Fixture &amp; Book</title></info>
  <chapter xml:id="chapter-one">
    <title>First chapter <indexterm><primary>alpha</primary></indexterm></title>
    <section xml:id="section-first"><title>First section</title><para>Text.</para></section>
    <section xml:id="section-second">
      <title>The word <foreignphrase xml:lang="jbo">di'u</foreignphrase> and more</title>
      <para>Text.</para>
      <section xml:id="sub-first"><title>First subsection</title><para>Text.</para>
        <section xml:id="sub-sub"><title>Too deep for the table of contents</title><para>Text.</para>
          <section xml:id="fourth-level"><title>Fourth level</title><para>Text.</para></section>
        </section>
      </section>
      <section xml:id="sub-second"><title>Second subsection</title><para>Text.</para>
        <section xml:id="deep-first"><title>Deep, on its parent's page</title><para>Text.</para></section>
        <section xml:id="deep-second"><title>Deep, and a page of its own</title><para>Text.</para></section>
      </section>
    </section>
  </chapter>
  <article xml:id="article-one">
    <title>An article</title>
    <section xml:id="section-article"><title>Article section</title><para>Text.</para></section>
  </article>
  <glossary><title>Glossary</title><glossentry><glossterm>term</glossterm><glossdef><para>Meaning.</para></glossdef></glossentry></glossary>
  <index/>
</book>
'''


def load_xml(path):
    text = Path(path).read_text(encoding='utf-8')
    text = re.sub(r'<!DOCTYPE[^>]*>', '', text)
    return ET.fromstring(text)


def norm(value):
    return re.sub(r'\s+', ' ', value or '').strip()


def nav_entries(path):
    nav = next(load_xml(path).iter(XHTML + 'nav'))

    def walk(ol, depth):
        found = []
        for li in ol.findall(XHTML + 'li'):
            link = li.find(XHTML + 'a')
            found.append((depth, link.get('href'), norm(''.join(link.itertext()))))
            sub = li.find(XHTML + 'ol')
            if sub is not None:
                found.extend(walk(sub, depth + 1))
        return found

    return walk(nav.find(XHTML + 'ol'), 1)


def visible_entries(path):
    toc = next(div for div in load_xml(path).iter(XHTML + 'div') if div.get('class') == 'toc')

    def walk(node, depth):
        found = []
        for child in list(node):
            if child.tag in LISTS:
                found.extend(walk(child, depth + 1))
            elif child.tag == XHTML + 'a':
                found.append((depth, child.get('href'), norm(''.join(child.itertext()))))
            else:
                found.extend(walk(child, depth))
        return found

    return walk(toc, 0)


def manifest_id(name):
    return re.sub(r'[_.\/-]', '', name)


class EpubNav(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cll-epub-nav-')
        root = Path(cls.temporary.name)
        xsl_zip = SOURCE / 'xml' / 'docbook-xsl-1.78.1.zip'
        with zipfile.ZipFile(xsl_zip) as archive:
            archive.extractall(root / 'xsl')
        xsl = root / 'xsl' / 'docbook-xsl-1.78.1'
        wrapper = root / 'wrapper.xsl'
        wrapper.write_text(
            "<?xml version='1.0'?>\n"
            '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">\n'
            f'<xsl:import href="{xsl}/xhtml5/chunk.xsl"/>\n'
            f'<xsl:include href="{SOURCE / "xml" / "docbook2html_config_epub.xsl"}"/>\n'
            '</xsl:stylesheet>\n'
        )
        book = root / 'book.xml'
        book.write_text(BOOK)
        cls.root = root
        cls.wrapper = wrapper
        cls.book = book

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def transform(self, out, nav=None, spine=None):
        out.mkdir(parents=True)
        command = ['xsltproc', '--nonet', '--xinclude']
        if nav is not None:
            nav.parent.mkdir(parents=True, exist_ok=True)
            command += ['--stringparam', 'cll.epub.nav.file', str(nav)]
        if spine is not None:
            spine.parent.mkdir(parents=True, exist_ok=True)
            command += ['--stringparam', 'generate.manifest', '1',
                        '--stringparam', 'manifest', str(spine)]
        command += [str(self.wrapper), str(self.book)]
        result = subprocess.run(
            command, cwd=out, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_navigation_matches_the_visible_table_of_contents(self):
        out = self.root / 'with-nav' / 'pages'
        nav = self.root / 'with-nav' / 'toc.xhtml'
        spine_path = self.root / 'with-nav' / 'spine.txt'
        plain = self.root / 'no-nav' / 'pages'
        self.transform(out, nav, spine_path)
        self.transform(plain, spine=self.root / 'no-nav' / 'spine.txt')

        pages = {path.name: path.read_bytes() for path in out.glob('*.html')}
        plain_pages = {path.name: path.read_bytes() for path in plain.glob('*.html')}
        self.assertEqual(pages, plain_pages)
        self.assertFalse((plain / 'toc.xhtml').exists())
        self.assertFalse((self.root / 'no-nav' / 'toc.xhtml').exists())

        text = nav.read_text(encoding='utf-8')
        self.assertIn('<!DOCTYPE html>', text)
        self.assertIn('<header>Table Of Contents</header>', text)
        nav_root = load_xml(nav)
        self.assertEqual(nav_root.tag, '{http://www.w3.org/1999/xhtml}html')
        self.assertEqual(nav_root.get('lang'), 'en')
        self.assertEqual(nav_root.get('{http://www.w3.org/XML/1998/namespace}lang'), 'en')
        entries = nav_entries(nav)
        self.assertEqual(entries, visible_entries(out / 'index.html'))
        self.assertGreater(len(entries), 0)

        chapter = next(label for _depth, href, label in entries if href == 'chapter-one.html')
        self.assertIn('First chapter', chapter)
        self.assertNotIn('alpha', chapter)
        labels = [label for _depth, _href, label in entries]
        self.assertTrue(any('Second subsection' in label for label in labels))
        for absent in (
            'Too deep for the table of contents',
            'Fourth level',
            'Deep, on its parent\'s page',
            'Deep, and a page of its own',
        ):
            self.assertFalse(any(absent in label for label in labels), absent)
        hrefs = [href for _depth, href, _label in entries]
        self.assertNotIn('deep-second.html', hrefs)

        for path in (nav, out / 'index.html'):
            phrases = [el for el in load_xml(path).iter() if el.get('class') == 'foreignphrase']
            self.assertGreaterEqual(len(phrases), 2, path)
            for phrase in phrases:
                self.assertEqual(phrase.get(XML_LANG), 'jbo')
                self.assertEqual(phrase.get('lang'), 'jbo')

        spine = [line.strip() for line in spine_path.read_text(encoding='utf-8').splitlines() if line.strip()]
        # enumerate-files lists each chunk once, parent before its children.
        self.assertEqual(spine, [
            'index.html',
            'chapter-one.html',
            'section-second.html',
            'sub-second.html',
            'deep-second.html',
            'article-one.html',
            'go01.html',
            'ix01.html',
        ])
        self.assertEqual(set(spine), set(pages))
        self.assertTrue(all('/' not in name for name in spine))

        package = self.package(out, nav, spine)
        self.assert_check(package, spine_path, 'Fixture & Book', 0)
        self.assert_check(package, spine_path, 'Wrong title', 1, 'title is')

        missing_file = self.clone(package)
        toc = (missing_file / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace('article-one.html"', 'missing.html"', 1)
        (missing_file / 'toc.xhtml').write_text(toc)
        self.assert_check(missing_file, spine_path, 'Fixture & Book', 1, 'missing file')

        missing_id = self.clone(package)
        toc = (missing_id / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace('chapter-one.html#section-first', 'chapter-one.html#not-a-real-id', 1)
        (missing_id / 'toc.xhtml').write_text(toc)
        self.assert_check(missing_id, spine_path, 'Fixture & Book', 1, 'missing id')

        repeated = self.clone(package)
        opf = (repeated / 'content.opf').read_text(encoding='utf-8')
        opf = opf.replace(
            '<itemref idref="indexhtml"/>',
            '<itemref idref="indexhtml"/>\n<itemref idref="indexhtml"/>',
            1,
        )
        (repeated / 'content.opf').write_text(opf)
        self.assert_check(repeated, spine_path, 'Fixture & Book', 1, 'spine names indexhtml 2 times')

        extra = self.clone(package)
        toc = (extra / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace('<ol>', '<ol><li><a href="index.html">Extra</a></li>', 1)
        (extra / 'toc.xhtml').write_text(toc)
        self.assert_check(extra, spine_path, 'Fixture & Book', 1, 'index.html shows')

        broken = self.clone(package)
        toc = (broken / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace('<ol>', '<ol><li><em>Broken</em></li>', 1)
        (broken / 'toc.xhtml').write_text(toc)
        self.assert_check(broken, spine_path, 'Fixture & Book', 1, 'has children')

        out_of_order = self.clone(package)
        toc = (out_of_order / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace('href="chapter-one.html"', 'href="__chapter__"', 1)
        toc = toc.replace('href="article-one.html"', 'href="chapter-one.html"', 1)
        toc = toc.replace('href="__chapter__"', 'href="article-one.html"', 1)
        (out_of_order / 'toc.xhtml').write_text(toc)
        self.assert_check(out_of_order, spine_path, 'Fixture & Book', 1, 'goes back in the reading order')

        omitted = self.clone(package)
        opf = (omitted / 'content.opf').read_text(encoding='utf-8')
        opf = opf.replace('<itemref idref="deepsecondhtml"/>\n', '', 1)
        (omitted / 'content.opf').write_text(opf)
        self.assert_check(omitted, spine_path, 'Fixture & Book', 1, 'page deep-second.html is not in the spine')

        no_nav = self.clone(package)
        toc = (no_nav / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace(' epub:type="toc"', '', 1)
        (no_nav / 'toc.xhtml').write_text(toc)
        self.assert_check(no_nav, spine_path, 'Fixture & Book', 1, 'has 0 toc nav elements')

        two_navs = self.clone(package)
        toc = (two_navs / 'toc.xhtml').read_text(encoding='utf-8')
        toc = toc.replace(
            '</nav>',
            '</nav><nav epub:type="toc"><ol><li><a href="index.html">Again</a></li></ol></nav>',
            1,
        )
        (two_navs / 'toc.xhtml').write_text(toc)
        self.assert_check(two_navs, spine_path, 'Fixture & Book', 1, 'has 2 toc nav elements')

        no_title = self.clone(package)
        toc = (no_title / 'toc.xhtml').read_text(encoding='utf-8')
        toc = re.sub(r'<title>.*?</title>', '', toc, count=1, flags=re.S)
        (no_title / 'toc.xhtml').write_text(toc)
        self.assert_check(no_title, spine_path, 'Fixture & Book', 1, 'toc.xhtml has no title')

    def package(self, pages, nav, spine):
        destination = self.root / 'package'
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir()
        for path in pages.glob('*.html'):
            text = re.sub(r'<!DOCTYPE[^>]*>\s*', '', path.read_text(encoding='utf-8'))
            (destination / path.name).write_text(text)
        shutil.copyfile(nav, destination / 'toc.xhtml')
        (destination / 'cover.html').write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Cover</p></body></html>\n'
        )
        items = [
            '<item id="cover" href="cover.html" media-type="application/xhtml+xml"/>',
            '<item id="toc" properties="nav" href="toc.xhtml" media-type="application/xhtml+xml"/>',
        ]
        refs = ['<itemref idref="cover"/>']
        for name in spine:
            items.append(
                f'<item id="{manifest_id(name)}" href="{name}" media-type="application/xhtml+xml"/>'
            )
            refs.append(f'<itemref idref="{manifest_id(name)}"/>')
        (destination / 'content.opf').write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">\n'
            '<manifest>\n' + '\n'.join(items) + '\n</manifest>\n'
            '<spine>\n' + '\n'.join(refs) + '\n</spine>\n'
            '</package>\n'
        )
        return destination

    def clone(self, package):
        copy = self.root / f'broken-{len(list(self.root.glob("broken-*")))}'
        shutil.copytree(package, copy)
        return copy

    def assert_check(self, package, spine_path, title, status, message=None):
        result = subprocess.run(
            ['ruby', str(SOURCE / 'scripts' / 'check_epub_nav.rb'),
             str(package), str(spine_path), title],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        self.assertEqual(result.returncode, status, result.stdout)
        if message is not None:
            self.assertIn(message, result.stdout)
        if status == 0:
            self.assertIn('correct', result.stdout)
        else:
            self.assertNotIn('NoMethodError', result.stdout)
            self.assertNotIn('Traceback', result.stdout)


if __name__ == '__main__':
    unittest.main()
