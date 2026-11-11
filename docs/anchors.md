# Anchors and stable links

The chapters contain `<anchor xml:id="..."/>` elements.
These anchors keep links to the book stable: a link to an anchor keeps working when the text around it moves.
Many of them date from the first edition and keep old links working.
In chapters 20 and 21, the book's own cross-references also point to anchors.
When you move text, move its anchor with it.
Never change or remove an existing anchor.

## Anchor forms

| Form | Marks | Example |
| --- | --- | --- |
| `cN` | Chapter N | `c5` |
| `cNsM` | Section M of chapter N | `c5s2` |
| `cNeMdK` | Example K of section M in chapter N | `c5e2d3` |

The book also uses these forms:

| Form | Marks | Example |
| --- | --- | --- |
| `cN-name` | A section of chapter N | `c21-intro`, `c21-peg` |
| `aN` | Appendix N | `a03` |
| `aN-name` | A section of appendix N | `a03-gadri` |

The chrestomathy section with the extract from *Alice in Wonderland* has the anchor `a0102`, which follows neither form.

Chapter 20 has one anchor for each selma'o, such as `BAI`.
Each EBNF rule in chapter 21 has two anchors: `bN` keeps old links working, and `cll_bnf-N` is the target of the EBNF cross-references.
`scripts/check-cross-reference.py` checks those anchors (see [checks.md](checks.md)).

When you add a section or an example, give it a new anchor in the same form.
Do not reuse the number of a removed section or example, because old links can still point to it.

Each `<example>` also has an `xml:id`, such as `example-random-id-qJKu`.
That ID is also permanent while the example exists.
See [markup-tags.md](markup-tags.md#examples).

## History

The first edition's HTML used one file per chapter, with anchors such as `chapter5.html#e2d3` for example 2.3 of chapter 5 and `chapter5.html#s2` for section 5.2.
Those anchors depended on the way the book was split into files.
The DocBook conversion kept the same names with a chapter prefix, so `#e2d3` in chapter 5 became `#c5e2d3`, and `#s2` became `#c5s2`.
The prefixed form is unique in the whole book, so it works in the single-page HTML too.
A web server can rewrite the old URLs to the new ones.
The original discussion is [lojban/cll#82](https://github.com/lojban/cll/issues/82).
