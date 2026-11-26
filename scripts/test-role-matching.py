#!/usr/bin/env python3
"""Role token-membership tests for the XSL stylesheets (issue #348).

DocBook @role is a whitespace-separated token list. Templates that match
@role must match by token membership (and preserve extra tokens as HTML
classes), never by exact whole-attribute equality.

Needs xsltproc. Does not build the book.
"""
import ast
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

SOURCE = Path(__file__).resolve().parent.parent
XHTML = '{http://www.w3.org/1999/xhtml}'

BOOK = '''<?xml version="1.0" encoding="UTF-8"?>
<book xmlns="http://docbook.org/ns/docbook" xml:lang="en">
  <info>
    <title>Fixture</title>
    <releaseinfo>
      <phrase role=" extra release-version ">v1.0</phrase>
      <phrase role=" release-separator extra "> | </phrase>
      <phrase role="release-date  extra">2026-11-25</phrase>
    </releaseinfo>
    <othercredit>
      <orgname role=" publication-notice extra ">Notice text<phrase role=" extra publication-disclaimer ">Disclaimer text</phrase></orgname>
    </othercredit>
  </info>
  <chapter xml:id="chapter-one">
    <title>First</title>
    <example xml:id="ex-padded" role=" interlinear-gloss-example extra ">
      <title>Padded</title>
      <para>Example body.</para>
    </example>
    <itemizedlist xml:id="list-plain" role="bullets">
      <listitem><para>One</para></listitem>
    </itemizedlist>
    <itemizedlist xml:id="list-multi" role=" extra  bullets ">
      <listitem><para>Two</para></listitem>
    </itemizedlist>
    <itemizedlist xml:id="list-sub" role="not-bullets">
      <listitem><para>Three</para></listitem>
    </itemizedlist>
  </chapter>
  <appendix xml:id="volume-chrestomathy">
    <title>Chrestomathy</title>
    <informaltable xml:id="tbl-plain" role="parallel-text">
      <tbody><tr><td>Plain</td><td>Plain EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-padded" role="  parallel-text  ">
      <tbody><tr><td>Padded</td><td>Padded EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-multi" role="parallel-text noborder">
      <tbody><tr><td>Multi</td><td>Multi EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-multi-rev" role="noborder parallel-text">
      <tbody><tr><td>MultiRev</td><td>MultiRev EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-prefix" role="not-parallel-text">
      <tbody><tr><td>Prefix</td><td>Prefix EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-suffix" role="parallel-text-2">
      <tbody><tr><td>Suffix</td><td>Suffix EN</td></tr></tbody>
    </informaltable>
  </appendix>
</book>
'''


class RoleMatchingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cll-roles-')
        root = Path(cls.temporary.name)
        with zipfile.ZipFile(SOURCE / 'xml' / 'docbook-xsl-1.78.1.zip') as z:
            z.extractall(root / 'xsl')
        xsl = root / 'xsl' / 'docbook-xsl-1.78.1'
        wrapper = root / 'wrapper.xsl'
        wrapper.write_text(
            "<?xml version='1.0'?>\n"
            '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">\n'
            f'<xsl:import href="{xsl}/xhtml5/docbook.xsl"/>\n'
            f'<xsl:include href="{SOURCE / "xml" / "docbook2html_config_prince.xsl"}"/>\n'
            '</xsl:stylesheet>\n',
            encoding='utf-8',
        )
        book = root / 'book.xml'
        book.write_text(BOOK, encoding='utf-8')
        out = root / 'out.html'
        r = subprocess.run(['xsltproc', '-o', str(out), str(wrapper), str(book)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise AssertionError(f'xsltproc failed: {r.stderr[:2000]}')
        text = re.sub(r'<!DOCTYPE[^>]*>', '', out.read_text(encoding='utf-8'))
        cls.doc = ET.fromstring(text)
        cls.by_id = {el.get('id'): el for el in cls.doc.iter() if el.get('id')}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_no_whole_value_role_match_in_xsl_stylesheets(self):
        # Guard the whole class across every project XSL file under xml/
        # (excluding any vendored docbook-xsl tree).
        # xml/docbook2html_config_headings.xsl is allowlisted by name because
        # its index-scope template is verbatim upstream DocBook XSL using
        # `$role = @role`.
        allowlisted_xsl = {'docbook2html_config_headings.xsl'}
        xsl_files = sorted(
            p for p in (SOURCE / 'xml').rglob('*.xsl')
            if not any(part.startswith('docbook-xsl') for part in p.relative_to(SOURCE / 'xml').parts)
        )
        self.assertTrue(xsl_files, 'expected project XSL files under xml/')

        bad_xsl_patterns = [
            ('whole-value @role comparison', re.compile(r"@role\s*!?=\s*['\"][^'\"]+['\"]")),
            ('reversed whole-value @role comparison', re.compile(r"['\"][^'\"]+['\"]\s*!?=\s*@role\b")),
            ('unpadded contains(@role, ...)', re.compile(r"contains\(\s*@role\b")),
            ('bare role= attribute pattern', re.compile(r"(?<![@A-Za-z0-9_-])role\s*!?=\s*['\"][^'\"]+['\"]")),
        ]

        # Self-check the guard patterns against every spelling we want to catch.
        for sample in (
            "para[@role='foo']",
            'para[@role="foo"]',
            "para[@role = 'foo']",
            "para['foo' = @role]",
            "para[@role != 'foo']",
            "para[contains(@role, 'foo')]",
            "para[role='foo']",
        ):
            self.assertTrue(
                any(pat.search(sample) for _, pat in bad_xsl_patterns),
                f'guard failed to flag XPath sample: {sample}',
            )

        findings = []
        for path in xsl_files:
            if path.name in allowlisted_xsl:
                continue
            tree = ET.parse(path)
            for el in tree.iter():
                for attr in ('match', 'test', 'select'):
                    expr = el.get(attr)
                    if not expr:
                        continue
                    for label, pat in bad_xsl_patterns:
                        for m in pat.finditer(expr):
                            findings.append(f'{path.relative_to(SOURCE)} ({attr}): {label}: {m.group(0)!r}')
        self.assertEqual(findings, [], 'Whole-value role checks in XSL:\n' + '\n'.join(findings))

    def test_no_whole_value_role_or_class_tests_in_scripts(self):
        # Guard non-test scripts against whole-value equality checks on DocBook
        # @role or HTML @class attributes (Ruby, Python, XPath, CSS).
        rb_patterns = [
            ('Ruby whole-value role/class comparison', re.compile(r"""\[['"](?:role|class)['"]\]\s*[!=]=\s*['"]""")),
            ('XPath whole-value @role/@class equality', re.compile(r"""@(?:role|class)\s*!?=\s*['"][^'"]+['"]""")),
            ('CSS whole-value [role=...] selector', re.compile(r"""\[(?:role|class)=[^~|^\$*\]"']+""")),
        ]
        py_regex_pat = re.compile(
            r"""(?:class|role)=\\?['"](?:\(\?:)?[A-Za-z0-9_|-]+\)?\\?['"]"""
        )

        def scan_python_source(src, rel):
            found = []
            tree = ast.parse(src, filename=rel)
            for node in ast.walk(tree):
                if isinstance(node, ast.Compare):
                    operands = [node.left, *node.comparators]
                    has_attr_lookup = False
                    has_str_const = False
                    for op in operands:
                        if (isinstance(op, ast.Call)
                                and isinstance(op.func, ast.Attribute)
                                and op.func.attr == 'get'
                                and op.args
                                and isinstance(op.args[0], ast.Constant)
                                and op.args[0].value in ('role', 'class')):
                            has_attr_lookup = True
                        if (isinstance(op, ast.Subscript)
                                and isinstance(op.slice, ast.Constant)
                                and op.slice.value in ('role', 'class')):
                            has_attr_lookup = True
                        if isinstance(op, ast.Constant) and isinstance(op.value, str) and op.value:
                            has_str_const = True
                    if (has_attr_lookup and has_str_const
                            and any(isinstance(o, (ast.Eq, ast.NotEq)) for o in node.ops)):
                        found.append(f'{rel}:{node.lineno}: Python whole-value role/class comparison')
                elif (isinstance(node, ast.Call)
                        and isinstance(node.func, ast.Attribute)
                        and isinstance(node.func.value, ast.Name)
                        and node.func.value.id == 're'
                        and node.func.attr in ('compile', 'search', 'match', 'fullmatch', 'sub', 'findall', 'finditer')
                        and node.args
                        and isinstance(node.args[0], ast.Constant)
                        and isinstance(node.args[0].value, str)):
                    m = py_regex_pat.search(node.args[0].value)
                    if m:
                        found.append(f'{rel}:{node.lineno}: Regex whole-value class/role attribute: {m.group(0)!r}')
            return found

        # Self-check script guards.
        for sample in (
            "node['role'] == 'bullets'",
            'row["class"] == "jbo"',
            "xpath('//div[@class=\"toc\"]')",
            "css('[role=natlang]')",
        ):
            self.assertTrue(
                any(pat.search(sample) for _, pat in rb_patterns),
                f'Ruby guard failed to flag: {sample}',
            )
        for sample in (
            "attrs.get('role') == 'parallel-text'",
            "attrs['class'] != 'toc'",
            're.compile(r\'<p class="(?:allowbreaks|twocolumn)">\')',
        ):
            self.assertTrue(
                scan_python_source(sample, '<sample>'),
                f'Python guard failed to flag: {sample}',
            )

        findings = []
        for path in sorted((SOURCE / 'scripts').rglob('*')):
            if not path.is_file():
                continue
            rel = path.relative_to(SOURCE).as_posix()
            if path.name.startswith('test-') or path.name.startswith('test_'):
                continue
            if 'htmldiff' in path.parts:
                continue
            if path.suffix == '.rb':
                for lineno, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
                    if line.lstrip().startswith('#'):
                        continue
                    for label, pat in rb_patterns:
                        for m in pat.finditer(line):
                            findings.append(f'{rel}:{lineno}: {label}: {m.group(0)!r}')
            elif path.suffix == '.py':
                findings.extend(scan_python_source(path.read_text(encoding='utf-8'), rel))
        self.assertEqual(findings, [], 'Whole-value role/class checks in scripts:\n' + '\n'.join(findings))

    def test_parallel_text_informaltable_role_tokens(self):
        self.assertEqual(self.by_id['tbl-plain'].get('class'), 'parallel-text informaltable')
        self.assertEqual(self.by_id['tbl-padded'].get('class'), 'parallel-text informaltable')
        self.assertEqual(self.by_id['tbl-multi'].get('class'), 'parallel-text noborder informaltable')
        self.assertEqual(self.by_id['tbl-multi-rev'].get('class'), 'noborder parallel-text informaltable')
        # Substring look-alikes must not match the parallel-text template.
        self.assertEqual(self.by_id['tbl-prefix'].get('class'), 'informaltable')
        self.assertEqual(self.by_id['tbl-suffix'].get('class'), 'informaltable')

    def test_bullets_itemizedlist_role_tokens(self):
        self.assertEqual(self.by_id['list-plain'].get('class'), 'bullets')
        self.assertEqual(self.by_id['list-multi'].get('class'), 'extra bullets')
        self.assertEqual(self.by_id['list-sub'].get('class'), 'itemizedlist')

    def test_example_role_normalizes_whitespace(self):
        self.assertEqual(
            self.by_id['ex-padded'].get('class'),
            'interlinear-gloss-example extra example',
        )

    def test_branding_roles_match_by_token(self):
        spans = {el.get('class'): ''.join(el.itertext())
                 for el in self.doc.iter(XHTML + 'span') if el.get('class')}
        self.assertEqual(spans.get('extra release-version'), 'v1.0')
        self.assertEqual(spans.get('release-separator extra'), ' | ')
        self.assertEqual(spans.get('release-date extra'), '2026-11-25')
        self.assertIn('Notice text', spans.get('orgname publication-notice extra', ''))
        self.assertEqual(spans.get('extra publication-disclaimer'), 'Disclaimer text')


if __name__ == '__main__':
    unittest.main()
