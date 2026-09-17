"""Knowledge-base tools for the water-knowledge wiki.

``search_wiki`` / ``read_wiki_page`` navigate the curated wiki under
``water_knowledge/wiki``, which is the only source the agent answers from for
questions about the collection. Paths are sandboxed to the wiki directory so
user input can never escape the knowledge base.

Pages cross-link by bare slug (``[[water-quality-analysis]]``) rather than by
path, so the readers below accept a slug, a ``[[wikilink]]`` or a relative path
interchangeably — the agent can follow a link it just read without having to
know which subdirectory the target lives in.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from strands import tool

# agent/tools/wiki.py -> repo root -> water_knowledge
DEFAULT_WIKI_ROOT = Path(__file__).resolve().parents[2] / "water_knowledge"


class WikiTool:
    MAX_CHARS = 30_000  # cap tool output so we don't blow up the context window
    _HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")

    def __init__(self, root: Path):
        self.root = root
        self.dir = self.root / "wiki"
        self.__slugs: dict[str, Path] | None = None

    def __safe_path(self, relative_path: str) -> Path:
        """Resolve a path relative to the wiki dir (index.md's own location).

        Sandboxing user-controlled paths prevents path-traversal file access.
        """
        # Resolve the base too: the candidate is resolved, so comparing it against
        # an unresolved root rejects everything when any parent is a symlink.
        base = self.dir.resolve()
        candidate = (base / relative_path.lstrip("/")).resolve()
        if base not in candidate.parents and candidate != base:
            raise ValueError(f"Path escapes the knowledge base: {relative_path}")
        return candidate

    def __slug_map(self, *, refresh: bool = False) -> dict[str, Path]:
        """Map lowercased page slug -> path, for resolving [[wikilinks]]."""
        if self.__slugs is None or refresh:
            self.__slugs = {
                md.stem.lower(): md for md in sorted(self.dir.rglob("*.md"))
            }
        return self.__slugs

    def __resolve(self, reference: str) -> Path:
        """Resolve a slug, [[wikilink]] or relative path to a wiki page.

        Raises ValueError for references that escape the wiki or match nothing.
        """
        ref = reference.strip().strip("[]").strip()
        if not ref:
            raise ValueError("Empty page reference.")

        candidates = [ref] if ref.endswith(".md") else [f"{ref}.md", ref]
        for candidate in candidates:
            try:
                path = self.__safe_path(candidate)
            except ValueError:
                raise ValueError(f"Path escapes the knowledge base: {reference}")
            if path.is_file():
                return path

        # Not a path — treat it as a bare slug and look it up anywhere in the wiki.
        # The wiki can change under us (it is served from a shared volume), so a
        # miss may just mean the page is new, and a hit may name a page that has
        # since moved. Either way, rebuild the map once before giving up.
        slug = Path(ref).stem.lower()
        match = self.__slug_map().get(slug)
        if match is None or not match.is_file():
            match = self.__slug_map(refresh=True).get(slug)
        if match:
            return match
        raise ValueError(f"Page not found: {reference}")

    def load_index(self) -> str:
        """Load wiki/index.md (the table of contents + intent map)."""
        index = self.dir / "index.md"
        return (
            index.read_text(encoding="utf-8")
            if index.exists()
            else "(index.md not found)"
        )

    def __split_sections(
        self, lines: list[str]
    ) -> list[tuple[str, list[tuple[int, str]]]]:
        """Split a page into (heading, [(line_no, text), ...]) sections.

        A section runs from one markdown heading to the next. Content before the
        first heading is grouped under an empty heading. Splitting by section (not
        by line) lets a query match terms that are spread across several lines of the
        same passage — e.g. a claim whose statement and citation are on different
        lines — which a line-by-line scan would miss.
        """
        sections: list[tuple[str, list[tuple[int, str]]]] = [("", [])]
        for i, ln in enumerate(lines, 1):
            m = self._HEADING_RE.match(ln)
            if m:
                sections.append((m.group(2).strip(), []))
            sections[-1][1].append((i, ln))
        return [s for s in sections if s[1]]

    @tool
    def search_wiki(self, query: str) -> str:
        """Search the water-knowledge wiki for a word or phrase.

        Use this to find which wiki page covers a topic, substance, person, place
        or source. Returns matching pages (relative paths) and the section heading
        where the match was found, with the lines that contained the search terms —
        so a claim spread across several lines of one passage still matches.

        Args:
            query: Words to search for, e.g. "residual chlorine" or
                "hardness soap test".
        """
        terms = [t for t in re.split(r"\s+", query.strip().lower()) if t]
        if not terms:
            return "Empty query."

        hits: list[str] = []
        for md in sorted(self.dir.rglob("*.md")):
            try:
                lines = md.read_text(encoding="utf-8").splitlines()
            except OSError:
                continue
            rel = md.relative_to(self.dir)

            for heading, body in self.__split_sections(lines):
                blob = "\n".join(text for _, text in body).lower()
                if not all(t in blob for t in terms):
                    continue
                # Show the lines that actually carried a term, as a snippet.
                snippet = [
                    f"  L{i}: {text.strip()}"
                    for i, text in body
                    if text.strip() and any(t in text.lower() for t in terms)
                ]
                location = f"{rel} › {heading}" if heading else str(rel)
                hits.append(location + "\n" + "\n".join(snippet[:6]))

        if not hits:
            return f"No matches for {query!r} in the wiki."
        return "\n\n".join(hits)[: self.MAX_CHARS]

    def __read_one(self, reference: str) -> str:
        try:
            path = self.__resolve(reference)
        except ValueError as exc:
            return str(exc)
        text = path.read_text(encoding="utf-8")
        if len(text) > self.MAX_CHARS:
            return (
                text[: self.MAX_CHARS] + f"\n... (truncated, {len(text)} chars total)"
            )
        return text

    @tool
    def read_wiki_page(self, relative_path: str) -> str:
        """Read a page from the water-knowledge wiki.

        Start with "index.md" to orient, then read the entry-point page and any
        pages it cross-links. Accepts a relative path ("topics/filtration.md"),
        or the bare slug a page links by ("filtration", "[[filtration]]") — slugs
        are resolved against the whole wiki, so you do not need to know which
        subdirectory a page lives in.

        Args:
            relative_path: Page path relative to index.md, or a page slug.
        """
        return self.__read_one(relative_path)

    @tool
    def read_wiki_pages(self, relative_paths: list[str]) -> str:
        """Read multiple pages from the water-knowledge wiki in one call.

        Use this instead of read_wiki_page whenever you already know you need more
        than one page — e.g. a topic page and the substance pages it cross-links, or
        a claim's page plus the source page it cites. Fetching them together avoids a
        separate round trip per page. Each entry may be a relative path or a slug.

        Args:
            relative_paths: Page paths relative to index.md, or page slugs.
        """
        if not relative_paths:
            return "No paths given."
        sections = [f"=== {rel} ===\n{self.__read_one(rel)}" for rel in relative_paths]
        return "\n\n".join(sections)[: self.MAX_CHARS]

    def tools(self) -> list:
        """Return the Strands tool callables bound to this wiki root."""
        return [self.search_wiki, self.read_wiki_page, self.read_wiki_pages]


def wiki_tools(root: Path | str | None = None) -> WikiTool:
    """Create wiki tools scoped to a knowledge-base root directory.

    Defaults to the bundled ``water_knowledge`` directory, overridable with the
    ``WATER_WIKI_ROOT`` environment variable (useful when the app runs in a
    container that mounts the wiki elsewhere).
    """
    return WikiTool(Path(root or os.getenv("WATER_WIKI_ROOT") or DEFAULT_WIKI_ROOT))
