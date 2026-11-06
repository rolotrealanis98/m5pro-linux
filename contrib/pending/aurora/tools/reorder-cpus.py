import re, sys
src, dst = sys.argv[1], sys.argv[2]
order = ["40000","40001","40002","40003","40004","40005","40100","40101","40102","40103","40104","40105","10200","10201","10202","10203","10204","10205"]
s = open(src).read()
m = re.search(r"\n(\tcpus \{\n)(.*?)(\n\t\};\n)", s, re.S)
body = m.group(2) + "\n"
# split body into top-level children of cpus: cpu@... { ... }; blocks at indent \t\t, keep other items (cpu-map, props) in place
pat = re.compile(r"(\t\tcpu@([0-9a-f]+) \{\n.*?\n\t\t\};\n)", re.S)
blocks = {mm.group(2): mm.group(1) for mm in pat.finditer(body)}
assert len(blocks) == 18, len(blocks)
rest = pat.sub("", body)
first = body.index("\t\tcpu@")
new_body = rest[:first].rstrip("\n") + "\n" + "".join(blocks[k] for k in order) + "\n" + rest[first:].lstrip("\n")
out = s[:m.start(2)] + new_body + s[m.end(2):]
open(dst, "w").write(out)
print("reordered", len(blocks), "cpu nodes")
