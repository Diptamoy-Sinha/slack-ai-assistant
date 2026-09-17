import re, pathlib, collections
root = pathlib.Path(".")
files = sorted(root.rglob("*.md"))
stems = {f.stem: f for f in files}
links = collections.defaultdict(set)   # target -> set of sources
for f in files:
    t = f.read_text(encoding="utf-8")
    for m in re.findall(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", t):
        links[m.strip()].add(f.stem)

print("== BROKEN LINKS (no target file) ==")
broken = {k: v for k, v in links.items() if k not in stems}
for k in sorted(broken):
    print(f"  {k:38s} <- {', '.join(sorted(broken[k]))}")
if not broken: print("  none")

print("\n== ORPHANS (nothing links here) ==")
linked = set(links)
orph = [s for s in sorted(stems) if s not in linked and s not in ("index",)]
for s in orph: print("  ", s)
if not orph: print("  none")

print("\n== PAGES WITH NO CITATION ==")
for f in files:
    t = f.read_text(encoding="utf-8")
    if not re.search(r"`\[(COC-1809|BUSH-1897|FFS-1961)", t) and f.stem not in ("SCHEMA","index","ingest-log"):
        print("  ", f)

print("\n== SINGLE-SOURCE TOPIC PAGES ==")
for f in sorted(root.glob("topics/*.md")):
    t = f.read_text(encoding="utf-8")
    keys = set(re.findall(r"`\[(COC-1809|BUSH-1897|FFS-1961)", t))
    if len(keys) < 2:
        print(f"   {f.stem:38s} {sorted(keys)}")

print("\n== FRONTMATTER sources vs body citations ==")
for f in files:
    t = f.read_text(encoding="utf-8")
    fm = re.search(r"^---\n(.*?)\n---", t, re.S)
    if not fm: continue
    decl = set(re.findall(r"(COC-1809|BUSH-1897|FFS-1961)", fm.group(1)))
    body = set(re.findall(r"`\[(COC-1809|BUSH-1897|FFS-1961)", t[fm.end():]))
    if decl != body and (decl or body):
        print(f"   {f.stem:38s} declared={sorted(decl)} cited={sorted(body)}")

print(f"\n== TOTALS: {len(files)} pages, {sum(len(v) for v in links.values())} link instances, {len(links)} distinct targets ==")
