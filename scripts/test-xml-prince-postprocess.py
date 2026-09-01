#!/usr/bin/env python3
"""Smoke test for scripts/xml_prince_postprocess.rb (issue #108).

That script is the last thing to touch the XHTML before Prince renders the
PDF, and it does its work with regular expressions over Nokogiri's serialized
output. Issue #106 was a defect in exactly that surface: the chapter-heading
marker was rewritten to a bare <br/>, so the heading's text content -- what
the PDF outline and any other text extraction see -- read
"Chapter\xa021Formal grammars". Nothing in the repository could catch that
short of building the book and reading the bookmark pane.

This test runs the real script, unmodified, on one small fixture that carries
one instance of each thing the script transforms, and asserts the resulting
document. It is a characterization test of the existing command-line
behavior, so it deliberately goes through the process boundary: ARGV[0], the
repository-root working directory, the real scripts/header.xml, Nokogiri's
own serialization, the order of the DOM and regex passes, stdout-only output,
and the exit status.

The central assertion is the heading's descendant text content, compared
without trimming or collapsing whitespace. Asserting merely that a <br/>
exists would pass both the defective and the corrected script; that is
precisely how #106 shipped.

Deliberately out of scope: Prince itself, PDF bytes, the DocBook-to-XHTML
transform, serializer indentation and attribute order, and error handling the
script does not currently promise.

Run: python3 scripts/test-xml-prince-postprocess.py
"""
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "xml_prince_postprocess.rb"
HEADER = ROOT / "scripts" / "header.xml"
FIXTURE = ROOT / "tests" / "fixtures" / "xml-prince-postprocess.xhtml"

# The separator xml/docbook2html_config_prince.xsl injects into chapter titles.
MARKER = "--CHAPBR--"

# An attribute on the fixture's own <book> start tag. The header substitution
# throws that tag away, so its survival means the substitution did not run --
# a check that finding a <book> root would not give us, since the replacement
# header supplies a <book> root of its own.
SENTINEL = "ORIGINAL-ROOT-MUST-BE-REPLACED"

# Spelled with escapes on purpose. The separator after "Chapter" is a no-break
# space -- the XSL writes it, and the script's xref-title regex matches on it --
# while the separator before the title is an ordinary space, the #106 fix.
# Written literally the two would be indistinguishable in review.
EXPECTED_HEADING_TEXT = "Chapter\u00a021\u0020Formal grammars"
EXPECTED_XREF_TITLE = "Formal grammars"
EXPECTED_XREF_TEXT = "Chapter\u00a021"

failures = []


def check(ok, label, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'}  {label}")
    if not ok:
        failures.append(label)
        if detail:
            print(f"        {detail}")
    return ok


def die(message):
    print(f"FAIL  {message}")
    print()
    print("test-xml-prince-postprocess: cannot continue")
    sys.exit(1)


def classes(elem):
    return (elem.get("class") or "").split()


def text_before(elem, stop):
    """Concatenated text of elem's subtree, in document order, up to `stop`.

    Nothing is trimmed or collapsed: the whitespace is the thing under test.
    """
    parts = []
    hit = False

    def walk(node):
        nonlocal hit
        if node is stop:
            hit = True
            return
        if node.text:
            parts.append(node.text)
        for child in node:
            walk(child)
            if hit:
                return
            if child.tail:
                parts.append(child.tail)

    walk(elem)
    return "".join(parts), hit


def run_postprocess():
    """Run the script the way scripts/Makefile does: from the repository root."""
    try:
        return subprocess.run(
            ["ruby", str(SCRIPT), str(FIXTURE)],
            cwd=str(ROOT),
            capture_output=True,
        )
    except FileNotFoundError:
        die("ruby is not on PATH; this test needs Ruby with the nokogiri gem")


def main():
    for path in (SCRIPT, HEADER, FIXTURE):
        if not path.is_file():
            die(f"missing {path}")

    proc = run_postprocess()
    stderr = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0:
        if "nokogiri" in stderr.lower() and "LoadError" in stderr:
            die("the nokogiri gem is not installed for this Ruby; "
                f"install it and re-run\n{stderr}")
        die(f"{SCRIPT.name} exited {proc.returncode}\n{stderr}")
    check(True, "the postprocessor exits 0")

    stdout = proc.stdout
    text = stdout.decode("utf-8")

    # --- header replacement, and the repository-root working directory -------
    header = HEADER.read_bytes()
    check(stdout.startswith(header),
          "stdout begins with the checked-in scripts/header.xml",
          f"first bytes were {stdout[:len(header)][:160]!r}")
    check(SENTINEL not in text,
          "the fixture's original root start tag is gone",
          f"the sentinel {SENTINEL!r} survived in the output")

    # --- no marker survives anywhere, not just in element text --------------
    check(MARKER not in text,
          f"no {MARKER} survives anywhere in stdout",
          f"{text.count(MARKER)} occurrence(s) left")

    # --- the output is well-formed XML --------------------------------------
    try:
        root = ET.fromstring(stdout)
    except ET.ParseError as exc:
        die(f"stdout is not well-formed XML: {exc}")
    check(root.tag == "book", "the parsed root element is <book>",
          f"root tag was {root.tag!r}")

    # --- chapter heading: marker becomes a break, and keeps a real space -----
    headings = [h for h in root.iter("h1")
                if "title" in classes(h)
                and h.find("a") is not None
                and h.find("a").get("id") == "chapter-grammars"]
    if len(headings) != 1:
        die(f"expected exactly 1 chapter heading in the output, found {len(headings)}")
    heading = headings[0]

    heading_text = "".join(heading.itertext())
    check(heading_text == EXPECTED_HEADING_TEXT,
          "the heading's text content is exactly "
          f"{EXPECTED_HEADING_TEXT!r}",
          f"actual {heading_text!r}")

    breaks = heading.findall(".//br")
    if not check(len(breaks) == 1, "the heading contains exactly one <br/>",
                 f"found {len(breaks)}"):
        die("cannot check the text around the break")

    prefix, found = text_before(heading, breaks[0])
    if not found:
        die("internal error: the heading's <br/> was not reached in document order")
    check(prefix[-1:] == " ",
          "the heading text before the <br/> ends in an ordinary space (U+0020)",
          f"actual prefix {prefix!r} (a no-break space U+00A0 or no space at all "
          "would leave the outline reading \"Chapter\\xa021Formal grammars\")")

    check(len(root.findall(".//br")) == 1,
          "the whole document contains exactly one <br/>",
          f"found {len(root.findall('.//br'))}")

    # --- xref title: chapter prefix and marker both stripped -----------------
    xrefs = [a for a in root.iter("a") if "xref" in classes(a)]
    if len(xrefs) != 1:
        die(f"expected exactly 1 xref in the output, found {len(xrefs)}")
    xref = xrefs[0]
    xref_title = xref.get("title")
    check(xref_title == EXPECTED_XREF_TITLE,
          f"the xref title is exactly {EXPECTED_XREF_TITLE!r}",
          f"actual {xref_title!r}")
    check("<br" not in (xref_title or ""),
          "the xref title contains no break markup",
          f"actual {xref_title!r}")
    xref_text = "".join(xref.itertext())
    check(xref_text == EXPECTED_XREF_TEXT,
          f"the xref's own link text is untouched ({EXPECTED_XREF_TEXT!r})",
          f"actual {xref_text!r}")

    # --- example anchor moved inside the title paragraph --------------------
    examples = [d for d in root.iter("div") if "example" in classes(d)]
    if len(examples) != 1:
        die(f"expected exactly 1 example div in the output, found {len(examples)}")
    example = examples[0]
    title_para = example.find("p[@class='title']")
    if title_para is None:
        die("the example div has no <p class=\"title\">")
    check(len(title_para) > 0
          and title_para[0].tag == "a"
          and title_para[0].get("id") == "c1e1",
          "the example anchor is the title paragraph's first element child",
          f"first child was {title_para[0].tag if len(title_para) else None!r} "
          f"id={title_para[0].get('id') if len(title_para) else None!r}")
    check([c for c in example if c.tag == "a"] == [],
          "the example anchor is no longer a sibling of the title paragraph",
          "an <a> is still a direct child of the example div")

    # --- outer index renamed; the inner one left alone ----------------------
    whole = [d for d in root.iter("div") if d.get("class") == "whole-index"]
    inner = [d for d in root.iter("div") if d.get("class") == "index"]
    check(len(whole) == 1,
          "exactly one div is renamed to class=\"whole-index\"",
          f"found {len(whole)}")
    check(len(inner) == 1,
          "the non-qualifying div keeps class=\"index\"",
          f"found {len(inner)} div(s) still classed \"index\"")
    if len(whole) == 1 and len(inner) == 1:
        first = whole[0][0] if len(whole[0]) else None
        check(first is not None
              and first.tag == "div"
              and first.get("class") == "titlepage",
              "the renamed div is the one whose first child is div.titlepage",
              f"first child was {None if first is None else first.tag!r} "
              f"class={None if first is None else first.get('class')!r}")
        check(whole[0].find(".//div[@class='index']") is inner[0],
              "the untouched index div is still nested inside the renamed one")

    print()
    if failures:
        print(f"test-xml-prince-postprocess: {len(failures)} assertion(s) failed:")
        for f in failures:
            print(" -", f)
        return 1
    print("test-xml-prince-postprocess: all assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
