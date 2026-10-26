import re
import sys

shas_path, src, dst = sys.argv[1:4]
shas = {}
with open(shas_path) as fh:
    for line in fh:
        parts = line.split()
        if len(parts) == 2:
            shas[parts[0]] = parts[1]
with open(src) as fh:
    text = fh.read()


def sub(m):
    key = "c" + m.group(1)
    if key not in shas:
        sys.exit("fill: no sha for %s" % key)
    return shas[key]


out = re.sub(r"\{c(\d\d)\}", sub, text)
with open(dst, "w") as fh:
    fh.write(out)
