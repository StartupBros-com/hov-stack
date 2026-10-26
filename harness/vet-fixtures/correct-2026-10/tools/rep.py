import sys

path, old, new = sys.argv[1:4]
with open(path) as fh:
    text = fh.read()
n = text.count(old)
if n != 1:
    sys.exit("rep: %d matches in %s for %r" % (n, path, old[:70]))
with open(path, "w") as fh:
    fh.write(text.replace(old, new))
