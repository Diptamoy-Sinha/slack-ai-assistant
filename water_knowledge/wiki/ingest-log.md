---
type: root
updated: 2026-09-14
---

# Ingest log

## 2026-09-14 — initial build, three sources

Wiki created from scratch. Schema, three source pages, fourteen topic pages,
eight substance pages, nine entity pages, four place pages.

### Sources ingested

| Source | Form | Method |
|---|---|---|
| [[conversations-on-chemistry-1809]] | 422-page searchable PDF, 113 MB | pypdf text layer → `raw/_text/conversations_on_chemistry.txt` (825 KB). 5 pages with no text layer. Water-relevant sections read in full; remainder surveyed by structure and keyword. |
| [[bush-recipes-aerated-mineral-waters-1897]] | 136-page searchable PDF, 24 MB | pypdf text layer → `raw/_text/recipes.txt` (135 KB). 1 page with no text layer. Front matter, General Instructions, Fermentation, Sediments, Mineral Waters and Analyses read in full. |
| [[family-food-stockpile-1961]] | 16 JPGs, no text layer | Downscaled to 1600 px (`raw/_text/stockpile_small/`) and read as images. Pages 1–7, 9–13 read; 8, 14–16 are meal-plan and blank record charts. |

### Extraction procedure

`pypdf` was installed into the project venv. Text extraction:

```python
# /tmp/extract_pdf.py — src, out
from pypdf import PdfReader
r = PdfReader(src)
chunks = [f"\n\n===== PAGE {i} =====\n{p.extract_text() or ''}"
          for i, p in enumerate(r.pages, 1)]
out.write_text("".join(chunks), encoding="utf-8")
```

The `===== PAGE n =====` markers are what the `(scan N)` half of every citation
refers to. Image downscaling used macOS `sips -Z 1600`.

### Coverage notes

Neither book was read cover to cover. Selection was driven by the collection's
stated subjects, located by keyword sweep over the extracted text with page
attribution. Sections **not** read closely:

- COC: Conversations IX (metals), XII–XIV, XVI–XXIII (vegetables, animals,
  respiration) except where a keyword hit pulled a page in; the Dyeing, Tanning
  and Currying appendices; the Yale Pneumatic Cistern description
- BUSH: the bulk of the flavoured-syrup recipes; the beer carbonating and
  bottling process; the list of sweetened beverages; most of the advertisements

Anything above may hold water material. A second pass is the obvious next ingest
even without new sources.

### Deliberate omissions

Marcet's Conversation XVIII on fermentation was read only via the contents
summary. It is the direct 1809 counterpart to Bush's fermentation chapter and
[[preservatives-and-antiseptics]] would be stronger with it read properly.

### Next

See [[open-questions]] for what the collection promises and these three sources
do not deliver — water-power, softening processes, magnesium from seawater,
and the non-print material.

## Related

[[SCHEMA]] · [[index]] · [[contradictions]] · [[open-questions]]

## 2026-09-14 — first lint pass

Run: `python3 wiki/lint.py` from the wiki directory.

Result: 44 pages, 351 wiki-link instances, 44 distinct targets. **No broken
links, no orphans, no uncited pages, no frontmatter drift.**

Fixed during the pass:
- `benjamin-silliman` and `ballston-spa` cited `BUSH-1897` without declaring it
- `preservatives-and-antiseptics` and `index` declared `FFS-1961` without citing
  it — resolved by adding the citation rather than dropping the declaration,
  since in both cases the 1961 comparison was the point
- Root pages had no `sources` frontmatter

**Two topic pages are legitimately single-source** and should not be flagged
again as incomplete synthesis:

- [[caloric-theory]] — the framework is Marcet's; Bush and the USDA pamphlet
  have no thermodynamics in them at all
- [[composition-of-water]] — Cavendish, Lavoisier and the classroom synthesis
  are 1809 only

Every other topic page draws on two or three sources.
