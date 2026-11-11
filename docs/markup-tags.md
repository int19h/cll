# Markup reference

The chapters in `chapters/` use DocBook 5 together with a set of custom elements for Lojban material.
This file lists the custom elements and the attributes that the chapters use.

The custom elements are not in the DTD (`dtd/docbook-5.0.dtd`).
The CI check (see [checks.md](checks.md)) tests only that the assembled book is well formed. It does not test the book against the DTD.
During a build, `scripts/xml_preprocess.rb` converts the custom elements to standard DocBook.
Most become `foreignphrase`, `para`, `phrase`, or table rows, and keep their old name in `role` (or `class` for table rows and cells).
The HTML, ePub, and PDF stylesheets in `xml/`, and the Typst and ConTeXt converters, read that converted XML.
The Typst and ConTeXt converters reject elements they do not know.
If you add a custom element, add its conversion to `scripts/xml_preprocess.rb` and check the other backends.

Status notes (`role="status-note"` with a `condition` attribute) have their own guide, [status-markup.md](status-markup.md).
The rules for anchors and example IDs are in [anchors.md](anchors.md).

## Inline Lojban

| Element | Use it for | Build result |
| --- | --- | --- |
| `valsi` | One Lojban word that the text talks about | A link to the glossary, an index term of type `lojban-word` (the Lojban words index), and `foreignphrase xml:lang="jbo"` |
| `cmevla` | A name (cmevla) that the text talks about | `foreignphrase xml:lang="jbo"`, with no glossary link |
| `jbophrase` | A run of Lojban words inside normal text | `foreignphrase xml:lang="jbo"` and an index term of type `lojban-phrase` |
| `letteral` | A Lojban letter, as a letter | `foreignphrase xml:lang="jbo"` |
| `diphthong` | A diphthong in a discussion of sounds | `foreignphrase xml:lang="jbo"` |
| `rafsi` | A rafsi (a combining form of a word) | `foreignphrase xml:lang="jbo"` |
| `morphology` | Other word-form material, such as a forbidden consonant pair | `foreignphrase xml:lang="jbo"` |

```xml
It is also possible to put the tense somewhere else in the bridi by adding <valsi>ku</valsi> after it.
<jbophrase>mi vasxu</jbophrase> (I breathe) is something which is true during the whole of my life.
As a result, <morphology>bf</morphology> is forbidden.
```

A `valsi` gets its glossary definition from the dictionary export in `dictionary/all_words.xml`.
Use `valsi` only for a word that you expect to find there, or mark it with `valid` as described below.
A `valsi` inside `title`, `term`, `primary`, or `secondary` gets no glossary link and no index entry.
A `jbophrase` in those elements gets no index entry.
`scripts/merge.sh` defines only the `lojban-word` and `general` indexes, and neither of them collects `lojban-phrase` terms.

For a compound cmavo whose meaning does not follow from its parts, use one element: `<valsi>.uinai</valsi>`.
For a compound that does decompose, use one element per part: `<valsi>je</valsi><valsi>nai</valsi>`.

A `jbophrase` that names a frame, such as `ke ... ke'e` or `lu ... li'u`, links each of its words to the glossary.
The words must be separated by `...` or `…`.
A `jbophrase` placed directly inside `example` becomes a paragraph of its own.

## The `valid` attribute

The `valid` attribute marks Lojban that is wrong or questionable on purpose.
[AGENTS.md](../AGENTS.md) requires a label on every intentionally invalid example.

| Element | Values in use | Meaning |
| --- | --- | --- |
| `valsi` | `false`, `maybe` | `false`: the word is ill formed. `maybe`: the word is well formed but is probably not in the dictionary, such as a lujvo made up for an example. |
| `cmevla` | `false`, `iffy` | `false`: the name is ill formed. `iffy`: the form is surprising or doubtful. |
| `jbophrase` | `false`, `iffy` | `false`: the phrase is ungrammatical. `iffy`: the phrase is doubtful. |
| `jbo` (inside an example) | `false`, `iffy` | The same meanings for a line of an example. |

```xml
<valsi valid="false">ro'irre'o</valsi>
<valsi valid="maybe">nunctikezgau</valsi>
<jbo valid="iffy">barda - xunre - gerku</jbo>
```

The attribute has these effects:

- A `valsi` with `false` or `maybe` gets no glossary link, no index entry, and no glossary entry. For `maybe`, the glossary step prints a note with the word.
- A `jbophrase` with `false` or `maybe` does not link the words of a frame. It still gets its index entry.
- `scripts/lint-word-spellings.rb` skips all text inside any element marked `false` or `maybe`. It still checks text marked `iffy`.
- The build removes the attribute, so the output does not mark such text.
- `scripts/extract-examples.py` ignores the attribute. The report-only example parse can therefore list marked lines as failures.

Some markup in the chapters has no effect on the output.
Do not add more of it:

- Some `sumti` and `gismu` elements carry `glossary="false"`. The build removes the attribute.
- `chapters/02.xml` has one `elidable delineated="false"`. The build removes the attribute, and the word still appears in brackets.
- `chapters/06.xml` has two `jbophrase role="ungrammatical"`. The build replaces the role with `jbophrase`, so the output does not mark them. To mark an ungrammatical phrase, use `valid="false"`.

## Examples

Most of the book's numbered examples use one of these patterns.
Each example has a permanent `xml:id` and an `anchor` in its title.
Never change or remove either while the example exists.
See [anchors.md](anchors.md) for the anchor forms.

The `role` attribute on `example` names the pattern.
The values in use are `interlinear-gloss-example`, `pronunciation-example`, `lojbanization-example`, `lujvo-example`, `lujvo-making-example`, and `compound-cmavo-example`.

### Interlinear gloss

An interlinear gloss shows a Lojban line with a word-by-word translation under it.

```xml
<example role="interlinear-gloss-example" xml:id="example-do-mamta-mi">
  <title><anchor xml:id="c5e1d1"/></title>
  <interlinear-gloss>
    <jbo>do mamta mi</jbo>
    <gloss>You are-a-mother-of me</gloss>
    <natlang>You are my mother</natlang>
  </interlinear-gloss>
</example>
```

`interlinear-gloss` accepts these children:

| Child | Content |
| --- | --- |
| `jbo` or `jbophrase` | The Lojban line. At least one is required. |
| `gloss` | The word-by-word English line |
| `natlang` | A free translation |
| `dbmath`, `mmlmath` | A formula (see [Mathematics](#mathematics)) |
| `para` | A full-width line of other text |

The element needs at least one `gloss`, `natlang`, `dbmath`, or `mmlmath`.
Any other child stops the build.
An `interlinear-gloss` can also stand outside an `example`, directly in a `section` or a table cell.

The build splits each `jbo` and `gloss` line at spaces, and each word goes into its own column.
These rules control the columns:

- Join the words of one gloss column with hyphens: `are-a-mother-of`.
- `--` joins two words into one column and prints a space between them.
- A lone `-` makes an empty column. `[-]` makes a column that shows `-`.
- A word directly before `<subscript>` stays in the same column as the subscript, as in `x<subscript>1</subscript>`.
- A word that ends in `-` directly before `<quote>` stays in the same column as the quote.
- The build hides a lone `…`.

`natlang` and `para` lines go into a second table under the columns.
Put `split="false"` on `interlinear-gloss` to keep them in one table.

`scripts/lint-gloss-columns.rb` checks that each `gloss` line has a column for every Lojban word.
It also checks the glosses of `cu`, `.i`, and terminators such as `ku` and `vau`.
The gloss of `cu` must be empty or punctuation.
The gloss of `.i` can also be `And`.
The gloss of a terminator can also be a label in square brackets.
To gloss a terminator in plain words, such as `unquote.` for `li'u`, put `role="gloss-lint-labeled-terminators"` on the `gloss`.
The script accepts only the plain-word labels in its `LABELS` table.
Put an XML comment directly before that `gloss`, with `gloss-lint:` and the reason.

### Itemized gloss

`interlinear-gloss-itemized` puts each sumti and selbri of a sentence into its own column.

```xml
<interlinear-gloss-itemized>
  <jbo>
    <sumti>mi</sumti>
    <elidable>cu</elidable>
    <selbri>vecnu</selbri>
    <sumti>ti</sumti>
  </jbo>
  <gloss>
    <sumti>I</sumti>
    <elidable/>
    <selbri>sell</selbri>
    <sumti>this</sumti>
  </gloss>
  <natlang>I sell this.</natlang>
</interlinear-gloss-itemized>
```

`jbo` and `gloss` contain `sumti`, `selbri`, `elidable`, `cmavo`, and `comment` elements.
Each one becomes a column.
The build puts an `elidable` word in square brackets, and an empty `elidable` prints `-`.
`elidable="false"` prints the word without brackets.
The other children of `interlinear-gloss-itemized` are `natlang`, `comment`, and loose `sumti`, `selbri`, or `elidable` elements.
Each becomes a full-width row.
`natlang` and `comment` rows go into a second table, as in an interlinear gloss, and the other rows stay in the first table.

### Pronunciation

```xml
<example role="pronunciation-example" xml:id="example-random-id-k2B4">
  <title><anchor xml:id="c3e3d1"/></title>
  <pronunciation>
    <jbo>.i.ai.i.ai.o</jbo>
    <ipa><phrase role="IPA">[ʔi ʔaj ʔi ʔaj ʔo]</phrase></ipa>
    <natlang>Ee! Eye! Ee! Eye! Oh!</natlang>
  </pronunciation>
</example>
```

`pronunciation` accepts `jbo`, `ipa`, `natlang`, and `comment`.
Each child becomes a line.
`ipa` matches the `jbo` line sound by sound.
A second `jbo` line with `role="pronunciation"` shows stress with capital letters, as in `.E'o ko ko KURji`.

### Compound cmavo

`compound-cmavo` shows a compound cmavo and its parts.
It accepts the same children as `pronunciation`.

```xml
<compound-cmavo>
  <jbo>.iseci'i</jbo>
  <jbo>.i se ci'i</jbo>
</compound-cmavo>
```

### Lojbanization

`lojbanization` shows how a word from another language becomes a Lojban word.
It accepts `jbo` and `natlang`, and each child becomes a full-width row.
Use `comment` inside a line to explain the step.

```xml
<lojbanization>
  <natlang>cobra</natlang>
  <jbo>kobra <comment>Lojbanize</comment></jbo>
  <jbo>sinc,r,kobra <comment>prefix rafsi</comment></jbo>
</lojbanization>
```

### Making lujvo

`lujvo-making` shows a lujvo (a compound word), the words that it comes from, and its meaning.

```xml
<lujvo-making>
  <jbo>vancysanmi</jbo>
  <veljvo>vanci sanmi</veljvo>
  <gloss><quote>evening meal</quote></gloss>
  <natlang>or <quote>supper</quote></natlang>
</lujvo-making>
```

Each child becomes a row.
`veljvo` prints as "from" followed by the source words, and gets an index term of type `lojban-phrase`.
For the scoring examples in chapter 4, use `rafsi` and `score`:

```xml
<lujvo-making>
  <jbo>zbasai</jbo>
  <rafsi>zba + sai</rafsi>
  <score><dbinlinemath>(1000 * 6) - (500 * 0) + (100 * 0) - (10 * 15) - 3 = 5847</dbinlinemath></score>
</lujvo-making>
```

### Comments

`comment` adds a remark to an example, such as `(Lojbanize)`.
The build treats it according to where it stands:

- Inside a `natlang` line, or inside a `jbo` or `natlang` line of a `lojbanization`, it becomes inline `emphasis role="comment"`.
- Inside the `jbo` or `gloss` line of an `interlinear-gloss-itemized`, it becomes a column of its own.
- Directly inside `pronunciation`, it becomes a line of its own, with the role `pronunciation-comment`.
- Directly inside `interlinear-gloss-itemized`, it becomes a full-width row in the second table.

## cmavo lists

Many sections start with a list of the cmavo that they discuss.

```xml
<cmavo-list>
  <cmavo-entry>
    <cmavo>bo</cmavo>
    <selmaho>BO</selmaho>
    <description>closest scope grouping</description>
  </cmavo-entry>
</cmavo-list>
```

The build turns `cmavo-list` into a table, and each `cmavo-entry` becomes a row.
A `cmavo-list` accepts `cmavo-entry`, `title`, and `cmavo-list-head`.
With a `title`, the list becomes a `table` with that caption. Without one, it becomes an `informaltable`.
`cmavo-list-head` contains `td` elements and becomes the table head.

A `cmavo-entry` accepts these children, and each becomes a cell:

| Child | Content |
| --- | --- |
| `cmavo` | The cmavo |
| `pseudo-cmavo` | A pattern that stands for a family of cmavo, such as `[N]roi` |
| `selmaho` | Its selma'o |
| `series` | Its series, such as `mi-series` |
| `gismu` | The related gismu |
| `rafsi` | A rafsi of the cmavo |
| `rafsi-group` | Several rafsi in one cell |
| `compound` | A compound form (the chapters do not use it now) |
| `modal-place` | The meaning of a BAI tag. Without `se`, it gives the plain form. `se="se"`, `"te"`, `"ve"`, or `"xe"` gives a converted form. |
| `attitudinal-scale` | One point of an attitudinal scale. `point="sai"`, `"cu'i"`, or `"nai"` names the point. |
| `description` | The meaning. `role` sets the cell class: `long`, `place-structure`, `direction`, or `movement` are in use. |

Any other child stops the build.

```xml
<cmavo-entry>
  <cmavo>.u'i</cmavo>
  <attitudinal-scale point="sai">amusement</attitudinal-scale>
  <attitudinal-scale point="nai">weariness</attitudinal-scale>
</cmavo-entry>

<cmavo-entry>
  <cmavo>bai</cmavo>
  <gismu>bapli</gismu>
  <modal-place>compelled by</modal-place>
  <modal-place se="se">compelling</modal-place>
</cmavo-entry>
```

## Definitions and grammar templates

`definition` shows the place structure of a word outside a cmavo list.
Put the place structure in `content`.

```xml
<definition>
  <valsi>mu'e</valsi>
  :
  <content>x<subscript>1</subscript> is a point event of (the bridi)</content>
</definition>
```

`grammar-template` shows a simplified grammar rule.

```xml
<grammar-template>.i [na] [se] JA [nai]</grammar-template>
```

Inside `title`, `term`, `member`, `secondary`, or `td`, both elements make an inline phrase.
Elsewhere, each makes a block quotation.

## Index terms

To add an index entry by hand, put an `indexterm` in the paragraph that the entry points to.
The chapters usually put it at the start of the paragraph:

```xml
<para><indexterm type="general"><primary>indefinite descriptions</primary></indexterm>By a quirk of Lojban syntax, ...</para>
```

`primary` holds the entry, and the optional `secondary` and `tertiary` hold subentries.
The `type` attribute chooses the index.
`scripts/merge.sh` makes only two indexes: `general` (the General Index) and `lojban-word` (the Lojban Words Index).
An `indexterm` of any other type reaches no index.
The build adds a `lojban-word` term for each `valsi` by itself, so most hand-written terms use `general`.

## Mathematics

| Element | Content | Build result |
| --- | --- | --- |
| `dbinlinemath` | Plain-text math inside a line | `inlineequation` with `mathphrase` |
| `dbmath` | Plain-text math as its own block | `informalequation` with `mathphrase` |
| `mmlinlinemath` | MathML content inside a line | `inlineequation` with MathML `math` |
| `mmlmath` | MathML content as its own block | `informalequation` with MathML `math display="block"` |

```xml
<dbmath>3:22:40 + 0:3:33 = 3:26:13</dbmath>

<mmlmath>
  <mrow>
    <mn>3</mn>
    <mo>&InvisibleTimes;</mo>
    <mi>x</mi>
  </mrow>
</mmlmath>
```

Write the MathML children without a `math` wrapper, because the build adds it.
The Typst converter supports only part of MathML.
See [typst-pdf.md](typst-pdf.md) for its limits.

## Roles on standard DocBook elements

These `role` and `class` values on standard elements are in use.
DocBook XSL copies `role` into the HTML `class`, and `assets/css/master.css` styles the classes.
The Typst and ConTeXt converters handle some of them too.

| Markup | Effect |
| --- | --- |
| `para role="noindent"` | Removes the first-line indent. The chapters also use `role="indent"`, which no stylesheet or converter treats specially. |
| `para role="allowbreaks"` | Lets the paragraph, and a table or example right after it, break across pages |
| `para role="twocolumn"` | Sets the following block in two columns |
| `para role="display-none"` | Hides the paragraph |
| `phrase role="IPA"`, `phrase role="X-SAMPA"` | Marks a phonetic transcription |
| `phrase role="logical-vowel"` | One of the vowels A, E, O, U that stand for logical connectives |
| `itemizedlist role="bullets"` | Shows bullets, which other lists do not |
| `informaltable class="vertsep"` | Separates rows with dotted lines |
| `informaltable class="noborder"` | Removes the vertical cell borders |
| `informaltable class="rotated"` | Removes the padding of nested tables, for a table laid out by rows, as in chapter 17 |
| `emphasis role="bold"` | Bold text |
