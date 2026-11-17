import sys
rows = {}
for l in sys.stdin:
    tag, _, pic = l.partition(" | picture t=2.000 ")
    if pic:
        rows[tag.strip()] = [tuple(map(int, c.split("/"))) for c in pic.split()]
for t, cells in rows.items():
    clip = t.split("-", 1)[1] if t.startswith("sw-") else t.split("-av1fix-", 1)[1]
    refname = "sw-" + clip if ("sw-" + clip) in rows else "vk-forced-av1fix-" + clip
    ref = rows[refname]
    md = max(abs(a - b) for c, r in zip(cells, ref) for a, b in zip(c, r))
    mg = max(abs(c[1] - r[1]) for c, r in zip(cells, ref))
    print(f"{t:40} vs {refname:36} max channel diff {md:3} (green {mg})")
