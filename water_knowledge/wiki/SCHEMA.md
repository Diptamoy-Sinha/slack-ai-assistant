# Schema

This document governs the structure and workflows of this wiki. **Read it before
ingesting a source or answering a query.** It is the only page a human is
expected to hand-edit.

## What this is

A water-history knowledge base compiled by an LLM from a digital collection of
primary sources on **water quality, testing, and analysis** — plus the
collection's adjacent subjects: distillation and filtration, water-power,
water-hardness and softening, and the extraction of magnesium from seawater.

Knowledge is **compiled once at ingest, not re-derived per query**. When a new
source arrives, the LLM reads it, extracts claims, and folds them into the
existing pages. Queries are answered from the wiki, not from the raw scans.

## Three layers

| Layer | Path | Mutability |
|---|---|---|
| Raw sources | `raw/` | Immutable. Never edit. |
| Extracted text | `raw/_text/` | Derived cache. Regenerable, never hand-edited. |
| The wiki | `wiki/` | LLM-written. Everything below. |

`raw/_text/` holds the OCR/text layer pulled out of the PDFs plus downscaled
page images. Regenerate with the extraction snippet in
[[ingest-log]]; do not treat it as authoritative where OCR is doubtful.

## Page types

Every page carries YAML frontmatter with `type`, `sources`, and `updated`.

| `type` | Directory | Holds |
|---|---|---|
| `source` | `wiki/sources/` | One per raw item: bibliographic record, structure, what it covers, what it is good evidence *for* |
| `topic` | `wiki/topics/` | A subject that cuts across sources — the synthesis layer, where the wiki earns its keep |
| `substance` | `wiki/substances/` | A chemical or material, under the name(s) the sources use |
| `entity` | `wiki/entities/` | A person or organisation |
| `place` | `wiki/places/` | A spring, spa, or manufacturing site |

Root-level pages: `index.md` (map), `timeline.md`, `open-questions.md`,
`contradictions.md`, `ingest-log.md`.

## Naming

`kebab-case.md`. People under the name they published as
(`jane-marcet.md`). Substances under the modern name, with the period name as
an alias in frontmatter (`magnesia-and-epsom-salt.md`, alias "sulphat of
magnesia"). Sources as `slug-year.md`.

## Citation rule

**Every factual claim carries a citation.** No exceptions — this is what makes
the wiki auditable against the scans.

Format: `[KEY p.PRINTED (scan N)]` where `PRINTED` is the page number printed on
the page and `N` is the page of the digitised file. Give `scan` whenever the two
differ, which for the two books is always.

Source keys:

| Key | Source page |
|---|---|
| `COC-1809` | [[conversations-on-chemistry-1809]] |
| `BUSH-1897` | [[bush-recipes-aerated-mineral-waters-1897]] |
| `FFS-1961` | [[family-food-stockpile-1961]] |

## Voice and stance

Write in the present tense about what a source *says*, past tense about what
happened. Do not silently modernise the chemistry: when a source says
"carbone", "sulphurated hydrogen", or "muriatic acid", quote it and gloss it —
the shifts in nomenclature are themselves part of the record.

**Never correct a period claim into a modern one.** Where a source is wrong by
modern lights, record what it says, then add a `> **Now:**` blockquote. Where
sources disagree with each other, both claims go on the topic page and the
disagreement goes in [[contradictions]].

## OCR discipline

Both books were OCR'd from scans and the text layer is noisy. When quoting:

- Silently repair only unambiguous character-level noise (`erated` → `ærated`,
  `srated` → `ærated`, `Salphat` → `Sulphat`).
- Mark any repair that changes meaning with `[sic: OCR]` and log it in
  [[contradictions]]. The 1809 `(1899)` for `(1809)` is the worked example.
- If a passage is too corrupt to quote, paraphrase and say so.
- Never quote from a page that the extractor reported as having no text layer
  without reading the page image first.

## Workflows

### Ingest

1. Add the raw item to `raw/`. Never modify it.
2. Extract text to `raw/_text/`. For image-only items, read the page images
   directly — do not guess at content.
3. Write or update the `source` page first: full bibliographic record, physical
   description, structure, provenance.
4. Walk the source for claims. For each, decide: does it land on an existing
   topic page, or does it need a new one? Prefer folding into an existing page.
5. Update every affected page — expect 10–15 per substantial source. Add the
   new source key to each page's `sources` frontmatter.
6. Add dated events to [[timeline]].
7. Log contradictions with existing pages in [[contradictions]]. Do not resolve
   them silently.
8. Append an entry to [[ingest-log]].

### Query

Answer from wiki pages, citing them. Follow the wiki-links rather than re-reading
`raw/`. Drop back to `raw/_text/` only when the wiki cannot answer — and when
that happens, the gap is itself a finding: file it in [[open-questions]] or fix
it by writing the missing page.

If an answer required real synthesis, file it back as a topic page. That is how
the wiki compounds.

### Lint

Run `python3 wiki/lint.py`, then check by hand for:

- Claims without citations
- Wiki-links with no target file (fine as intent markers, but they should be
  short-lived — a long-lived one is a gap worth filling)
- Orphan pages nothing links to
- Contradictions that have quietly resolved, or new ones that have not been logged
- Topic pages citing only one source — a sign the synthesis has not happened yet
- `sources` frontmatter that has drifted from the citations in the body
