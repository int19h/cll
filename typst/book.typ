// CLL's print design, expressed independently of the HTML stylesheets.
#let cll-book(title: "", author: "", body) = {
  set document(title: title, author: author)
  set text(font: ("Linux Libertine O", "Noto Serif SC", "Noto Serif KR"), size: 9pt, lang: "en", ligatures: false, hyphenate: false, top-edge: 0.8em, bottom-edge: -0.2em)
  set par(justify: true, leading: 0.14em, spacing: 2.16pt)
  set block(above: 0pt, below: 0pt)
  set page(width: 159mm, height: 240mm, margin: (x: 13mm, y: 17mm),
    header: context {
      let heads = query(<cll-header>).filter(h => h.location().page() <= here().page())
      if here().page() > 1 and heads.len() > 0 {
        let on-page = heads.filter(h => h.location().page() == here().page())
        let current = if on-page.len() > 0 { on-page.first().value } else { heads.last().value }
        align(center, text(size: 9pt, if calc.even(here().page()) { title } else { current }))
      }
    },
    footer: context if here().page() > 1 {
      align(if calc.even(here().page()) { left } else { right }, text(size: 10pt, counter(page).display()))
    },
    header-ascent: 2mm, footer-descent: 2mm,
  )
  show math.equation: set text(font: "New Computer Modern Math", ligatures: true)
  show link: set text(fill: black)
  show heading.where(level: 1): it => {
    block(above: 10pt, below: 10pt, sticky: true)[#align(center, text(size: 14pt, weight: "bold", it.body))]
  }
  show heading.where(level: 2): it => block(above: 10pt, below: 2pt, sticky: true)[#text(size: 11pt, weight: "bold", it.body)]
  show heading.where(level: 3): it => block(above: 8pt, below: 2pt, sticky: true)[#strong(it.body)]
  show raw: set text(font: "DejaVu Sans Mono", size: 8pt)
  body
}

#let cll-title(title, subtitle, author, credits, release) = {
  set par(justify: false)
  align(center)[
    #v(10pt)
    #text(size: 52pt, weight: "bold", title)
    #if subtitle != "" { block(above: 12pt)[#text(size: 16pt, subtitle)] }
    #v(60pt)
    #text(size: 16pt, author)
    #if credits.len() > 0 { block(above: 9pt)[#emph(credits.first())] }
    #v(1fr)
    #for credit in credits.slice(calc.min(1, credits.len())) { block[#text(size: 14pt, weight: "bold", credit)] }
    #block(above: 10pt)[#text(release)]
    #v(15pt)
  ]
  pagebreak()
}

#let cll-heading(level, prefix, short-title, marks: [], body) = {
  if level == 1 { pagebreak(to: "odd", weak: true) }
  block(height: 0pt, sticky: true)[#marks#if level <= 2 { [#metadata(if prefix == "" { short-title } else { prefix + " " + short-title })<cll-header>] }]
  heading(level: level, numbering: none)[
    #if prefix != "" { text(prefix); if level == 1 { linebreak() } else { h(0.4em) } }
    #body
  ]
}

#let cll-par(indent: false, body) = {
  set par(first-line-indent: if indent { (amount: 1em, all: true) } else { 0pt })
  body
  parbreak()
}

#let cll-status(body) = block(inset: (left: 0.75em), outset: (left: -0.75em), stroke: (left: 1.5pt + gray), above: 4.5pt, below: 4.5pt)[
  #set text(size: 0.92em)
  #text(fill: gray)[◆] #body
]

#let cll-example(number, breakable: false, title, body) = block(inset: (left: 2em), above: 4.5pt, below: 4.5pt, breakable: breakable)[
  #set par(justify: false, first-line-indent: 0pt, spacing: 0pt)
  #block(sticky: true, below: 3pt)[#strong[Example #number #title]]
  #body
]

#let cll-table(cols, border: true, rows: 0, vertsep: false, ..cells) = {
  set par(justify: false, first-line-indent: 0pt, spacing: 0pt, leading: 0.14em)
  block(above: 1.8pt, below: 1.8pt)[
    #table(columns: (auto,) * cols, inset: (x: 0.4em, y: 0.63pt), align: left + top,
      stroke: (x, y) => (
        left: if border and x > 0 { (paint: gray, thickness: 0.5pt, dash: "dotted") } else { none },
        bottom: if vertsep and y < rows - 1 { (paint: gray, thickness: 0.5pt, dash: "dotted") } else { none },
      ),
      ..cells.pos(),
    )
  ]
}

#let cll-image(path, description) = block(above: 6pt, below: 6pt)[
  #align(center, image(path, height: 150pt, width: 90%, fit: "contain", alt: description))
]

#let cll-gloss(term, definition) = {
  set par(justify: false, first-line-indent: 0pt, spacing: 0pt)
  block(sticky: true)[#strong(term)]
  block(inset: (left: 2em), below: 1pt)[#definition]
}

// Collect page locations in one query. The index follows the content, so its
// own length cannot move the locations it references.
#let cll-index(entries) = context {
  let pages = (:)
  for mark in query(<cll-index>) {
    let key = mark.value
    let found = pages.at(key, default: ())
    let page = mark.location().page()
    if found.len() == 0 or found.last().page != page {
      found.push((page: page, loc: mark.location()))
      pages.insert(key, found)
    }
  }
  columns(2, gutter: 5mm)[
    #set text(size: 0.9em)
    #set par(justify: false, first-line-indent: 0pt, spacing: 0pt, leading: 0.14em)
    #for entry in entries {
      let refs = if entry.key == none { () } else { pages.at(entry.key, default: ()) }
      let ranges = ()
      for ref in refs {
        if ranges.len() > 0 and ref.page <= ranges.last().last.page + 1 {
          let old = ranges.pop()
          ranges.push((first: old.first, last: ref))
        } else {
          ranges.push((first: ref, last: ref))
        }
      }
      block(inset: (left: entry.depth * 0.8em), sticky: entry.key == none)[
        #entry.body#if ranges.len() > 0 { [: ] }
        #for (i, range) in ranges.enumerate() {
          if i > 0 { [, ] }
          link(range.first.loc, str(range.first.page))
          if range.last.page > range.first.page {
            [–]
            link(range.last.loc, str(range.last.page))
          }
        }
        #if entry.see.len() > 0 { [; #emph[see] #entry.see.join(", ")] }
        #if entry.seealso.len() > 0 { [; #emph[see also] #entry.seealso.join(", ")] }
      ]
    }
  ]
}

#let cll-ref(id, caption) = context {
  let target = query(label(id)).first().location()
  link(target)[#caption (p. #counter(page).at(target).first())]
}
