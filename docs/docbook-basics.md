# DocBook basics

The book is written in DocBook 5, an XML format for books.
This page shows the standard markup that a chapter uses.
[markup-tags.md](markup-tags.md) describes the custom elements for Lojban material, and [AGENTS.md](../AGENTS.md) gives the editorial rules.

## A chapter

Each file in `chapters/` holds one chapter or appendix:

```xml
<chapter xml:id="chapter-dialects">
  <title><anchor xml:id="c22" />Beyond the standard: dialects and experimental Lojban</title>
  <section xml:id="section-dialects-introduction">
    <title><anchor xml:id="c22s1" />What this chapter is, and is not</title>
    <para>The main reference chapters of this book teach ...</para>
  </section>
</chapter>
```

- `chapter` contains a `title` and one `section` element for each numbered section.
- `section` contains a `title` and the text of the section.
- `para` is one paragraph.
- `quote` puts its text in quotation marks: `<quote>experimental cmavo</quote>`. Do not type the quotation marks yourself.
- `emphasis` is italic text.

## Links

`xref` links to another part of the book by its `xml:id`.
The output shows the number or title of the target, so do not write that text yourself:

```xml
<xref linkend="section-pro-sumti" />
<xref linkend="example-random-id-VKU6" />
```

`link` links with your own text, to a place in the book or to a web page:

```xml
<link linkend="chapter-about-picture">Chapter 1</link>
<link xlink:href="https://www.loglan.org/">loglan.org</link>
```

## Special characters

XML gives `&` and `<` a special meaning.
In text, write them as `&amp;` and `&lt;`.
You can also use the named entities that `scripts/header.xml` loads, such as `&ndash;` for an en dash and `&hellip;` for an ellipsis.
The well-formedness check in [checks.md](checks.md) fails on an entity that is not defined.

## IDs for new sections and examples

Every `xml:id` must be unique in the whole book.
A new section or example needs two IDs: an `xml:id` on the element and an `anchor` in its title.

| Element | `xml:id` | Anchor in the title |
| --- | --- | --- |
| Section | `section-` and a short name, such as `section-dialects-introduction` | `cNsM` for section M of chapter N, such as `c22s1` |
| Example | `example-random-id-` and four letters or digits, such as `example-random-id-x22a` | `cNeMdK` for example K of section M in chapter N, such as `c22e2d1` |

Take the next free number for the anchor.
If you insert a section before others, keep their anchors as they are.
Never renumber or reuse an existing anchor.
[anchors.md](anchors.md) explains why and lists the other anchor forms.

Before you commit, search for the new IDs to make sure that nothing else uses them:

```sh
grep -rn 'xml:id="example-random-id-x22a"' chapters/
```

The well-formedness check also fails on a duplicate ID.
