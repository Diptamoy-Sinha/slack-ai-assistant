---
type: root
sources: [COC-1809, BUSH-1897, FFS-1961]
updated: 2026-09-14
---

# Water knowledge

An LLM-compiled wiki over a digital collection on **water quality, testing and
analysis** — with distillation and filtration, water-power, water-hardness and
softening, and the extraction of magnesium from seawater as adjacent subjects.

Built from three primary sources spanning 152 years. Read [[SCHEMA]] before
ingesting anything or answering from these pages.

## Sources

| Key | Source | Date |
|---|---|---|
| `COC-1809` | [[conversations-on-chemistry-1809]] — Jane Marcet, third American edition | 1809 |
| `BUSH-1897` | [[bush-recipes-aerated-mineral-waters-1897]] — W. J. Bush & Co. trade manual | 1897 |
| `FFS-1961` | [[family-food-stockpile-1961]] — USDA civil-defence pamphlet | 1961 |

## Start here

If you want **one page**, read [[water-quality-analysis]] — it is where all three
sources meet and disagree.

Three arcs run the length of the collection:

**Imitating a spring.** Marcet's claim that analysis lets you copy nature
exactly `[COC-1809 p.121]` → an 1809 fountain of gilt urns and silver taps at
the Tontine Coffee House → ten named springs on a London price list, and
prosecutions for selling soda water with no soda in it `[BUSH-1897 p.87]`.
[[mineral-waters]] · [[artificial-carbonation]] · [[benjamin-silliman]]

**Who decides the water is safe.** A professor tasting it (1809) → a paid
analyst charging a guinea for four determinands (1897) → a householder smelling
for residual chlorine because the health department may no longer exist (1961).
[[water-quality-analysis]] · [[water-purification]] · [[waterborne-contamination]]

**What we are afraid of.** Nothing much — mineral content is the *product*
(1809) → lead, germs, and adulteration `[BUSH-1897 p.20]` → radioactive fallout
`[FFS-1961 p.12]`. One fear is constant: dissolved metal you cannot see or
taste.
[[waterborne-contamination]]

## Topics

**Treating water**
[[water-purification]] · [[filtration]] · [[distillation]] · [[water-storage]]

**Judging water**
[[water-quality-analysis]] · [[waterborne-contamination]] ·
[[water-hardness-and-softening]]

**The trade**
[[mineral-waters]] · [[artificial-carbonation]] ·
[[preservatives-and-antiseptics]]

**The science**
[[composition-of-water]] · [[water-as-solvent]] ·
[[evaporation-and-the-water-cycle]] · [[caloric-theory]]

## Substances

[[carbonic-acid]] · [[sodium-bicarbonate]] · [[magnesia-and-epsom-salt]] ·
[[lime]] · [[sulphurated-hydrogen]] · [[charcoal]] · [[sodium-hypochlorite]] ·
[[tincture-of-iodine]]

## People and organisations

[[jane-marcet]] · [[humphry-davy]] · [[henry-cavendish]] ·
[[antoine-lavoisier]] · [[benjamin-silliman]] · [[baron-de-bush]] ·
[[w-j-bush-and-co]] · [[usda]] · [[office-of-civil-and-defense-mobilization]]

## Places

[[harrogate]] · [[seltzer-water]] · [[ballston-spa]] · [[epsom]]

## Wiki apparatus

[[SCHEMA]] — page types, citation rule, ingest/query/lint workflows
[[timeline]] — dated events across all sources
[[contradictions]] — OCR artefacts, internal inconsistencies, superseded claims
[[open-questions]] — what the collection promises that these sources do not deliver
[[ingest-log]] — what was read, how, and what was skipped
`lint.py` — the link/citation checker the lint workflow runs

## Citing

Every claim carries `[KEY p.PRINTED (scan N)]`. `PRINTED` is the page number on
the page; `scan N` is the page of the digitised file, which for both books
differs from it. Offsets: COC printed + ~36 = scan; BUSH printed + 4 = scan.
FFS printed page = scan page.
