#!/usr/bin/env python3
"""session-index-backend: the full-text engine under session-search.py. Standard library only.

    build  <docs.jsonl> <dir>      index a batch into an empty folder
    update <docs.jsonl> <dir>      add a batch (same code path as build)
    remove <dir> <files.txt>       drop every doc of the named files (one `file` value per line)
    query  <dir> <limit> <query>   the best doc of each of the `limit` best sessions, one JSON line
                                   each: {"session", "id", "preview"}
    check  <dir>                   exit 0 when the folder is empty or holds an index this file
                                   reads, 4 when it holds an index in another format

A doc is one JSON line: {"id": "<prefix>:<line>:<block>", "session", "file", "text", ...}. A doc
matches when it holds every word of the query; words are runs of letters and digits, lower-cased.
There are no phrases, prefixes or positions.

Layout (format 2). A segment is one file written once (tmp + rename) and listed in manifest.json,
which is the commit point and names the format. Postings are positionless and sorted by a 48-bit
hash of the word. A list is cut into blocks of 128 docs: the gaps between doc ids are Rice-coded
with the parameter chosen per block, and each doc carries a 4-bit quantised BM25 impact (tf and
doc length folded in with a fixed average length), so a query reads no doc lengths. The word
dictionary is a table of 4 KiB pages addressed by hash range (one page per probe); an entry is the
low 5 bytes of the hash (all 6 in a table of under 512 pages), then either the doc and impact of a
word found in one doc, or the length and offset of its list. A doc record is 12 bytes: session,
file, line, block. Previews are the first 200 characters, 32 docs to a zlib block, compressed
against a preset dictionary sampled from the index's first batch (prev.dict, written once). `file`
and the id prefix are kept verbatim per file; `remove` marks that file's docs dead in each segment,
and a merge drops dead docs.

update = write one new segment, commit, then merge size tiers (FANOUT segments of one tier become
one, of at most CAP_DOCS docs), streaming by hash slice so memory stays bounded. Files are opened
with FADV_RANDOM: with the default readahead a cold query read megabytes it never used.

Another format. Every command stops with exit 4, before it reads or writes a segment, when the
manifest names a format other than this file's. Nothing is converted: session-search.py empties
the folder and indexes the archive again.

Limits. Two words can share a 48-bit hash; they then share one postings list, so a query for
either may also return a doc holding only the other. A doc that holds the word is never missed.
A query reads the whole postings list of its rarest word in every segment. An impact has 15
levels, so docs that exact BM25 would order can tie.

This is the docseg-bm25 line of the session-search index campaign (hov-stack issue 885).
"""
import array
import bisect
import collections
import hashlib
import json
import math
import os
import re
import struct
import sys
import zlib

TOKEN = re.compile(r"[^\W_]+")
PAGE = 4096
ENT = 15                      # in-memory entry: hash48 | u32 w | u40 offset (w = df, or docid | impact<<24 when df == 1)
QMAX = 15                     # impact levels (4 bits)
K1, B = 1.2, 0.75


class _Doc:
    """Doc record, 12 bytes: session idx and file idx as 24 bits each, line u32, block u16."""
    _s = struct.Struct("<HBHBIH")
    size = 12

    @classmethod
    def pack(cls, sid, fid, ln, bi, _pad=0):
        return cls._s.pack(sid & 0xFFFF, sid >> 16, fid & 0xFFFF, fid >> 16, ln, bi)

    @classmethod
    def unpack_from(cls, buf, off):
        a, b, c, d, ln, bi = cls._s.unpack_from(buf, off)
        return (a | b << 16, c | d << 16, ln, bi, 0)


DOC = _Doc
ZD = b""                    # zlib preset dictionary for previews, kept in the index folder (prev.dict)
ZD_BYTES = 16384
FMT = 2                       # on-disk format: 2 = Rice gaps, 4-bit impacts, packed dictionary, preview dictionary
STALE = 4                     # exit status when the folder holds an index in another format
PREV_N = 32                   # docs per preview block
PREV_CHARS = 200
FANOUT = 24
CAP_DOCS = 12_000_000         # merged segment never exceeds this (doc ids stay below 1 << 24)
MAXDOCS = 1 << 24
SPILL = 48 << 20


def pz(raw):
    c = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, ZD) if ZD else zlib.compressobj(9)
    return c.compress(raw) + c.flush()


def pu(blob):
    return (zlib.decompressobj(zdict=ZD) if ZD else zlib.decompressobj()).decompress(blob)


def load_dict(index_dir):
    global ZD
    try:
        with open(os.path.join(index_dir, "prev.dict"), "rb") as fh:
            ZD = fh.read()
    except FileNotFoundError:
        ZD = b""


def train_dict(docs, index_dir):
    """First batch of an index: a preset dictionary from every 25th preview of its first 40000 docs."""
    global ZD
    if os.path.exists(os.path.join(index_dir, "prev.dict")):
        load_dict(index_dir)
        return
    sample = []
    with open(docs, "rb") as fh:
        for i, line in enumerate(fh):
            if i >= 40000:
                break
            if i % 25 == 0:
                sample.append(json.loads(line)["text"][:PREV_CHARS])
    ZD = json.dumps(sample).encode("ascii")[-ZD_BYTES:]
    tmp = os.path.join(index_dir, "prev.dict.tmp")
    with open(tmp, "wb") as fh:
        fh.write(ZD)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, os.path.join(index_dir, "prev.dict"))


def h48(term):
    return int.from_bytes(hashlib.blake2b(term.encode("utf-8", "surrogatepass"), digest_size=6).digest(), "big")


def rice_pack(gaps):
    """-> (k, bytes): Rice code of non-negative gaps, k chosen per block."""
    n = len(gaps)
    tot = sum(gaps)
    k0 = max(0, (tot // n).bit_length() - 1)
    kmax = max(0, max(gaps).bit_length() - 4)
    best = None
    for k in {max(0, k0 - 1), k0, k0 + 1, kmax}:
        bits = sum(g >> k for g in gaps) + n * (k + 1)
        if best is None or bits < best[0]:
            best = (bits, k)
    k = best[1]
    mask = (1 << k) - 1
    acc = 0
    nbits = 0
    for g in gaps:
        w = (g >> k) + 1 + k
        acc = (acc << w) | (1 << k) | (g & mask)
        nbits += w
    pad = -nbits % 8
    return k, (acc << pad).to_bytes((nbits + pad) // 8, "big")


def rice_unpack(buf, n, k):
    nbits = len(buf) * 8
    s = bin(int.from_bytes(buf, "big"))[2:].rjust(nbits, "0")
    pos = 0
    out = []
    find = s.index
    for _ in range(n):
        j = find("1", pos)
        q = j - pos
        pos = j + 1
        if k:
            out.append((q << k) | int(s[pos:pos + k], 2))
            pos += k
        else:
            out.append(q)
    return out


def nib_pack(imps):
    v = list(imps)
    if len(v) & 1:
        v.append(0)
    return bytes((a << 4) | b for a, b in zip(v[0::2], v[1::2]))


def nib_unpack(data, n):
    out = bytearray(2 * len(data))
    out[0::2] = bytes(b >> 4 for b in data)
    out[1::2] = bytes(b & 15 for b in data)
    return out[:n]


def encode_block(ids, imps, prev):
    gaps = [ids[0] - prev] + [b - a for a, b in zip(ids, ids[1:])]
    k, rb = rice_pack(gaps)
    return bytes((k,)) + rb + nib_pack(imps)


def decode_block(buf, n, prev):
    """buf is one whole block -> (ids, imps)."""
    k = buf[0]
    nn = (n + 1) // 2
    gaps = rice_unpack(buf[1:len(buf) - nn], n, k)
    ids = []
    for g in gaps:
        prev += g
        ids.append(prev)
    return ids, nib_unpack(buf[len(buf) - nn:], n)


def encode_list(ids, imps):
    """-> bytes: one block as [len u16][block]; several as [(last u32, len u16) per block] + blocks."""
    df = len(ids)
    nblk = (df + 127) // 128
    blocks, dirs = [], []
    prev = 0
    for i in range(nblk):
        lo = i * 128
        sl = ids[lo:lo + 128]
        blk = encode_block(sl, imps[lo:lo + 128], prev)
        prev = sl[-1]
        blocks.append(blk)
        dirs.append((sl[-1], len(blk)))
    if nblk > 1:
        return b"".join(struct.pack("<IH", a, n) for a, n in dirs) + b"".join(blocks)
    return struct.pack("<H", len(blocks[0])) + blocks[0]


def decode_list(buf, pos, df):
    if df <= 128:
        ln = struct.unpack_from("<H", buf, pos)[0]
        return decode_block(buf[pos + 2:pos + 2 + ln], df, 0)
    nblk = (df + 127) // 128
    lasts, lens = [], []
    for i in range(nblk):
        a, ln = struct.unpack_from("<IH", buf, pos + i * 6)
        lasts.append(a)
        lens.append(ln)
    p = pos + nblk * 6
    ids, imps = [], bytearray()
    prev = 0
    for i in range(nblk):
        n = min(128, df - i * 128)
        a, b = decode_block(buf[p:p + lens[i]], n, prev)
        ids.extend(a)
        imps += b
        prev = lasts[i]
        p += lens[i]
    return ids, imps


def read_manifest(index_dir):
    """The manifest, its segment list under "segs". On disk the list is named "segments": the
    format 1 engine reads "segs" and checks no format, so on a format 2 folder it stops with a
    KeyError before it writes, where it would otherwise add a format 1 segment to this index."""
    p = os.path.join(index_dir, "manifest.json")
    if not os.path.exists(p):
        return {"fmt": FMT, "avgdl": None, "segs": [], "next": 0}
    with open(p) as fh:
        man = json.load(fh)
    if man.get("fmt") != FMT:
        sys.stderr.write(f"index format {man.get('fmt')!r} is not {FMT}: the index has to be built again\n")
        sys.exit(STALE)
    man["segs"] = man.pop("segments")
    return man


def write_manifest(index_dir, man):
    p = os.path.join(index_dir, "manifest.json")
    on_disk = dict(man)
    on_disk["segments"] = on_disk.pop("segs")
    with open(p + ".tmp", "w") as fh:
        json.dump(on_disk, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(p + ".tmp", p)
    fd = os.open(index_dir, os.O_RDONLY)     # the renames of this commit, segment files included
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sample_avgdl(docs):
    n = tot = 0
    with open(docs, "rb") as fh:
        for line in fh:
            tot += len(TOKEN.findall(json.loads(line)["text"].lower()))
            n += 1
            if n >= 20000:
                break
    return max(1.0, tot / max(1, n))


# ------------------------------------------------------------------ writing a segment

class DocSide:
    """Doc records, previews, session and file tables of one segment under construction."""

    def __init__(self, spill_dir=None):
        self.recs = bytearray()
        self.pdata = bytearray()
        self.poffs = array.array("I", [0])
        self.pbuf = []
        self.sessions, self.files = {}, {}
        self.sess_names, self.file_names = [], []
        self.n = 0
        self.plen = 0
        self.spill = spill_dir
        self.fr = self.fp = None
        if spill_dir:
            self.fr = open(os.path.join(spill_dir, "recs.tmp"), "wb")
            self.fp = open(os.path.join(spill_dir, "pdata.tmp"), "wb")

    def sess(self, name):
        i = self.sessions.get(name)
        if i is None:
            i = self.sessions[name] = len(self.sess_names)
            self.sess_names.append(name)
        return i

    def file(self, entry):
        i = self.files.get(entry)
        if i is None:
            i = self.files[entry] = len(self.file_names)
            self.file_names.append(entry)
        return i

    def add(self, sid, fid, ln, bi, preview):
        self.recs += DOC.pack(sid, fid, ln, bi, 0)
        self.pbuf.append(preview)
        self.n += 1
        if len(self.pbuf) == PREV_N:
            self.flush_block()
        if self.spill and len(self.recs) > SPILL:
            self.fr.write(self.recs)
            self.recs = bytearray()

    def flush_block(self):
        if not self.pbuf:
            return
        z = pz(json.dumps(self.pbuf).encode("ascii"))
        self.pbuf = []
        self.pdata += z
        self.plen += len(z)
        self.poffs.append(self.plen)
        if self.spill and len(self.pdata) > SPILL:
            self.fp.write(self.pdata)
            self.pdata = bytearray()

    def finish(self):
        self.flush_block()
        if self.spill:
            self.fr.write(self.recs)
            self.fp.write(self.pdata)
            self.fr.close()
            self.fp.close()
            self.recs = self.pdata = None

    def table(self, strs):
        offs = array.array("I")
        blob = bytearray()
        for s in strs:
            offs.append(len(blob))
            blob += s.encode("utf-8", "surrogatepass")
        offs.append(len(blob))
        return offs.tobytes() + bytes(blob)

    def write_to(self, fo, pos):
        """Append recs, previews, preview offsets, tables. Returns (offsets dict, new pos)."""
        o = {}
        o["o_docs"] = pos
        if self.spill:
            with open(os.path.join(self.spill, "recs.tmp"), "rb") as fh:
                while True:
                    c = fh.read(1 << 24)
                    if not c:
                        break
                    fo.write(c)
                    pos += len(c)
            o["o_pdata"] = pos
            with open(os.path.join(self.spill, "pdata.tmp"), "rb") as fh:
                while True:
                    c = fh.read(1 << 24)
                    if not c:
                        break
                    fo.write(c)
                    pos += len(c)
        else:
            fo.write(self.recs)
            pos += len(self.recs)
            o["o_pdata"] = pos
            fo.write(self.pdata)
            pos += len(self.pdata)
        o["o_poffs"] = pos
        b = self.poffs.tobytes()
        fo.write(b)
        pos += len(b)
        o["o_sess"] = pos
        b = self.table(self.sess_names)
        fo.write(b)
        pos += len(b)
        o["o_files"] = pos
        b = self.table(self.file_names)
        fo.write(b)
        pos += len(b)
        o["nsess"], o["nfiles"] = len(self.sess_names), len(self.file_names)
        return o, pos


class SegWriter:
    """Terms must arrive in ascending hash order."""

    def __init__(self, path, spill_dir):
        self.path = path
        self.fo = open(path, "wb")
        self.spill_dir = spill_dir
        self.pos = 0
        self.ents = bytearray()
        self.efile = None
        self.nterms = 0
        self.slices = [0] * 257
        self.cs = 0

    def add_term(self, h, ids, imps):
        df = len(ids)
        s = h >> 40
        while self.cs <= s:
            self.slices[self.cs] = self.pos
            self.cs += 1
        if df == 1:
            f, off = ids[0] | (imps[0] << 24), 0
        else:
            data = encode_list(ids, imps)
            f, off = df, self.pos
            self.fo.write(data)
            self.pos += len(data)
        self.ents += h.to_bytes(6, "big") + struct.pack("<I", f) + off.to_bytes(5, "little")
        self.nterms += 1
        if len(self.ents) > SPILL:
            if self.efile is None:
                self.efile = open(os.path.join(self.spill_dir, "ents.tmp"), "wb")
            self.efile.write(self.ents)
            self.ents = bytearray()

    def entries(self):
        if self.efile is not None:
            self.efile.write(self.ents)
            self.efile.close()
            self.ents = bytearray()
            with open(os.path.join(self.spill_dir, "ents.tmp"), "rb") as fh:
                while True:
                    c = fh.read(ENT * 1000000)
                    if not c:
                        break
                    yield c
        else:
            yield bytes(self.ents)

    def finish(self, docside):
        while self.cs <= 256:
            self.slices[self.cs] = self.pos
            self.cs += 1
        post_len = self.pos
        o_dict = post_len + (-post_len) % PAGE
        self.fo.write(b"\0" * (o_dict - post_len))
        tot = 0
        for chunk in self.entries_again():
            for i in range(0, len(chunk), ENT):
                tot += 10 if chunk[i + 9] else 15
        nb = max(1, int(tot / 3800) + 1)
        while True:
            kb = 5 if nb >= 512 else 6
            sums = array.array("I", [0]) * nb
            ok = True
            for chunk in self.entries_again():
                for i in range(0, len(chunk), ENT):
                    b = (int.from_bytes(chunk[i:i + 6], "big") * nb) >> 48
                    sums[b] += kb + 4 + (0 if chunk[i + 9] else 5)
                    if sums[b] > PAGE - 2:
                        ok = False
            if ok:
                break
            nb = int(nb * 1.03) + 1
        cur = 0
        page = bytearray()
        n_in = 0

        def flush():
            self.fo.write(struct.pack("<H", n_in) + bytes(page) + b"\0" * (PAGE - 2 - len(page)))

        for chunk in self.entries_again():
            for i in range(0, len(chunk), ENT):
                b = (int.from_bytes(chunk[i:i + 6], "big") * nb) >> 48
                while cur < b:
                    flush()
                    page = bytearray()
                    n_in = 0
                    cur += 1
                page += chunk[i + 6 - kb:i + 10]
                if not chunk[i + 9]:
                    page += chunk[i + 10:i + 15]
                n_in += 1
        while cur < nb:
            flush()
            page = bytearray()
            n_in = 0
            cur += 1
        pos = o_dict + nb * PAGE
        o, pos = docside.write_to(self.fo, pos)
        self.fo.flush()
        os.fsync(self.fo.fileno())
        self.fo.close()
        for t in ("ents.tmp", "recs.tmp", "pdata.tmp"):
            try:
                os.unlink(os.path.join(self.spill_dir, t))
            except OSError:
                pass
        meta = {"ndocs": docside.n, "nb": nb, "o_post": 0, "o_dict": o_dict, "nterms": self.nterms,
                "post_len": post_len, "slices": self.slices, "dead": [], "size": pos}
        meta.update(o)
        return meta

    def entries_again(self):
        if self.efile is None:
            yield bytes(self.ents)
            return
        if not self.efile.closed:
            self.efile.write(self.ents)
            self.efile.close()
            self.ents = bytearray()
        with open(os.path.join(self.spill_dir, "ents.tmp"), "rb") as fh:
            while True:
                c = fh.read(ENT * 1000000)
                if not c:
                    break
                yield c


def file_entry(rec):
    prefix = rec["id"].rsplit(":", 2)[0]
    return rec["file"] if prefix == rec["file"] else rec["file"] + "\0" + prefix


def build_segment(docs, index_dir, man):
    avgdl = man["avgdl"]
    seqno = man["next"]
    ds = DocSide()
    P = {}
    ndocs = 0
    tokfind = TOKEN.findall
    counter = collections.Counter
    with open(docs, "rb") as fh:
        for line in fh:
            r = json.loads(line)
            text = r["text"]
            toks = tokfind(text.lower())
            _, ln, bi = r["id"].rsplit(":", 2)
            ds.add(ds.sess(r["session"]), ds.file(file_entry(r)), int(ln), int(bi), text[:PREV_CHARS])
            if toks:
                dl = len(toks)
                norm = K1 * (1 - B + B * dl / avgdl)
                for t, c in counter(toks).items():
                    q = 1 + int(QMAX * c / (c + norm))
                    e = P.get(t)
                    if e is None:
                        P[t] = e = (array.array("I"), bytearray())
                    e[0].append(ndocs)
                    e[1].append(q)
            ndocs += 1
    if ndocs >= MAXDOCS:
        sys.exit("batch too large for one segment")
    ds.finish()
    name = "seg-%05d.bin" % seqno
    tmp = os.path.join(index_dir, name + ".tmp")
    w = SegWriter(tmp, index_dir)
    order = sorted((h48(t), t) for t in P)
    i = 0
    while i < len(order):
        h = order[i][0]
        j = i
        while j < len(order) and order[j][0] == h:
            j += 1
        if j - i == 1:
            ids, imps = P[order[i][1]]
        else:                                  # terms sharing a hash share one list (best impact wins)
            best = {}
            for _, t in order[i:j]:
                for d, q in zip(*P[t]):
                    if q > best.get(d, 0):
                        best[d] = q
            ids = array.array("I", sorted(best))
            imps = bytearray(best[d] for d in ids)
        w.add_term(h, ids, imps)
        i = j
    meta = w.finish(ds)
    os.replace(tmp, os.path.join(index_dir, name))
    meta["name"] = name
    return meta


# ------------------------------------------------------------------ segment reading helpers

def read_table(fd, base, n, end):
    raw = os.pread(fd, end - base, base)
    offs = struct.unpack("<%dI" % (n + 1), raw[:4 * (n + 1)])
    blob = raw[4 * (n + 1):]
    return [blob[offs[i]:offs[i + 1]].decode("utf-8", "surrogatepass") for i in range(n)]


def seg_tables(index_dir, seg):
    fd = os.open(os.path.join(index_dir, seg["name"]), os.O_RDONLY)
    try:
        size = os.fstat(fd).st_size
        sess = read_table(fd, seg["o_sess"], seg["nsess"], seg["o_files"])
        files = read_table(fd, seg["o_files"], seg["nfiles"], size)
    finally:
        os.close(fd)
    return sess, files


def remove(index_dir, files_path):
    man = read_manifest(index_dir)
    with open(files_path, encoding="utf-8") as fh:
        names = set(line.rstrip("\n") for line in fh if line.strip())
    if not names:
        return
    for seg in man["segs"]:
        dead = set(seg["dead"])
        _, files = seg_tables(index_dir, seg)
        for i, e in enumerate(files):
            if e.split("\0", 1)[0] in names:
                dead.add(i)
        seg["dead"] = sorted(dead)
    write_manifest(index_dir, man)


# ------------------------------------------------------------------ merging

def iter_chunks(fd, start, end, size=1 << 22):
    pos = start
    while pos < end:
        c = os.pread(fd, min(size, end - pos), pos)
        if not c:
            break
        yield c
        pos += len(c)


def key_bytes(nb):
    return 5 if nb >= 512 else 6


def parse_dict_range(page_bytes, lo_h, hi_h, nb, b_lo):
    """Entries (hash, df, off, impact) of consecutive pages starting at page b_lo."""
    kb = key_bytes(nb)
    out = []
    for pi in range(len(page_bytes) // PAGE):
        p = pi * PAGE
        cnt = struct.unpack_from("<H", page_bytes, p)[0]
        plo = (((b_lo + pi) << 48) + nb - 1) // nb
        base = (plo >> 40) << 40
        o = p + 2
        for _ in range(cnt):
            key = int.from_bytes(page_bytes[o:o + kb], "big")
            if kb == 5:
                h = base | key
                if h < plo:
                    h += 1 << 40
            else:
                h = key
            w = struct.unpack_from("<I", page_bytes, o + kb)[0]
            o += kb + 4
            if w >> 24:
                e = (h, 1, w & 0xFFFFFF, w >> 24)
            else:
                e = (h, w, int.from_bytes(page_bytes[o:o + 5], "little"), 0)
                o += 5
            if lo_h <= h < hi_h:
                out.append(e)
    return out


def merge_segments(index_dir, srcs, seqno):
    name = "seg-%05d.bin" % seqno
    tmp = os.path.join(index_dir, name + ".tmp")
    ds = DocSide(spill_dir=index_dir)
    fds = [os.open(os.path.join(index_dir, s["name"]), os.O_RDONLY) for s in srcs]
    try:
        remaps, newbase = [], []
        # docs pass: records and previews, dead docs dropped
        for s, fd in zip(srcs, fds):
            sess, files = seg_tables(index_dir, s)
            dead = set(s["dead"])
            nd = s["ndocs"]
            remap = array.array("i", [-1]) * nd if dead else None
            newbase.append(ds.n)
            sid_map = [ds.sess(x) for x in sess]
            fid_map = [ds.file(x) for x in files]
            nblk = (nd + PREV_N - 1) // PREV_N
            poffs = struct.unpack("<%dI" % (nblk + 1), os.pread(fd, 4 * (nblk + 1), s["o_poffs"]))
            d = 0
            blk = 0
            recs_it = iter_chunks(fd, s["o_docs"], s["o_docs"] + nd * DOC.size, DOC.size * 65536)
            recs_buf = b""
            rpos = 0
            while d < nd:
                # decode previews of the next group of blocks in one read
                b1 = min(nblk, blk + 256)
                data = os.pread(fd, poffs[b1] - poffs[blk], s["o_pdata"] + poffs[blk])
                prevs = []
                for k in range(blk, b1):
                    prevs.extend(json.loads(pu(data[poffs[k] - poffs[blk]:poffs[k + 1] - poffs[blk]])))
                blk = b1
                for p in prevs:
                    if rpos + DOC.size > len(recs_buf):
                        recs_buf = recs_buf[rpos:] + next(recs_it)
                        rpos = 0
                    sid, fid, ln, bi, _ = DOC.unpack_from(recs_buf, rpos)
                    rpos += DOC.size
                    if fid not in dead:
                        if remap is not None:
                            remap[d] = ds.n
                        ds.add(sid_map[sid], fid_map[fid], ln, bi, p)
                    d += 1
            remaps.append(remap)
        ds.finish()
        # postings passes by hash slice
        total_terms = sum(s["nterms"] for s in srcs)
        total_post = sum(s["post_len"] for s in srcs)
        ngroups = min(256, max(1, int(total_terms / 1_500_000) + 1, int(total_post / (128 << 20)) + 1))
        step = 256 // ngroups + (1 if 256 % ngroups else 0)
        w = SegWriter(tmp, index_dir)
        for s0 in range(0, 256, step):
            s1 = min(256, s0 + step)
            lo_h, hi_h = s0 << 40, s1 << 40
            tab = {}
            bufs = []
            for si, (s, fd) in enumerate(zip(srcs, fds)):
                nb = s["nb"]
                b_lo = (lo_h * nb) >> 48
                b_hi = ((hi_h - 1) * nb) >> 48
                pages = os.pread(fd, (b_hi - b_lo + 1) * PAGE, s["o_dict"] + b_lo * PAGE)
                for h, df, off, imp in parse_dict_range(pages, lo_h, hi_h, nb, b_lo):
                    tab.setdefault(h, []).append((si, df, off, imp))
                a, b = s["slices"][s0], s["slices"][s1]
                bufs.append((a, os.pread(fd, b - a, s["o_post"] + a) if b > a else b""))
            for h in sorted(tab):
                ids = array.array("I")
                imps = bytearray()
                for si, df, off, imp in tab[h]:
                    if df == 1:
                        l_ids, l_imps = [off], [imp]
                    else:
                        a, buf = bufs[si]
                        l_ids, l_imps = decode_list(buf, off - a, df)
                    remap = remaps[si]
                    if remap is None:
                        base = newbase[si]
                        ids.extend([d + base for d in l_ids])
                        imps += bytes(l_imps)
                    else:
                        for d, q in zip(l_ids, l_imps):
                            nd_ = remap[d]
                            if nd_ >= 0:
                                ids.append(nd_)
                                imps.append(q)
                if ids:
                    w.add_term(h, ids, imps)
            del tab, bufs
        meta = w.finish(ds)
    finally:
        for fd in fds:
            os.close(fd)
    os.replace(tmp, os.path.join(index_dir, name))
    meta["name"] = name
    return meta


def tier(ndocs):
    return int(math.log(max(ndocs, 1), FANOUT) + 1e-9)


def pick_merge(segs):
    by = collections.defaultdict(list)
    for s in segs:
        if s["ndocs"] < CAP_DOCS // 2:
            by[tier(s["ndocs"])].append(s)
    for t in sorted(by):
        group = sorted(by[t], key=lambda s: s["ndocs"])
        if len(group) >= FANOUT:
            pick, tot = [], 0
            for s in group[:FANOUT]:
                if tot + s["ndocs"] > CAP_DOCS:
                    break
                pick.append(s)
                tot += s["ndocs"]
            if len(pick) >= 2:
                return pick
    return None


def clean(index_dir, man):
    keep = set(s["name"] for s in man["segs"]) | {"manifest.json"}
    for fn in os.listdir(index_dir):
        if fn not in keep and (fn.startswith("seg-") or fn.endswith(".tmp")):
            try:
                os.unlink(os.path.join(index_dir, fn))
            except OSError:
                pass


def ingest(docs, index_dir):
    os.makedirs(index_dir, exist_ok=True)
    man = read_manifest(index_dir)
    clean(index_dir, man)
    if man["avgdl"] is None:
        train_dict(docs, index_dir)
    else:
        load_dict(index_dir)
    if man["avgdl"] is None:
        man["avgdl"] = sample_avgdl(docs)
    meta = build_segment(docs, index_dir, man)
    man["segs"].append(meta)
    man["next"] += 1
    write_manifest(index_dir, man)
    while True:
        pick = pick_merge(man["segs"])
        if not pick:
            break
        meta = merge_segments(index_dir, pick, man["next"])
        man["next"] += 1
        names = set(s["name"] for s in pick)
        man["segs"] = [s for s in man["segs"] if s["name"] not in names] + [meta]
        write_manifest(index_dir, man)
        for n in names:
            try:
                os.unlink(os.path.join(index_dir, n))
            except OSError:
                pass


# ------------------------------------------------------------------ query

class Seg:
    def __init__(self, index_dir, meta):
        self.m = meta
        self.fd = os.open(os.path.join(index_dir, meta["name"]), os.O_RDONLY)
        try:
            os.posix_fadvise(self.fd, 0, 0, os.POSIX_FADV_RANDOM)
        except (AttributeError, OSError):
            pass
        self.dead = set(meta["dead"])
        self.pages = {}

    def rd(self, off, n):
        return os.pread(self.fd, n, off)

    def lookup(self, term):
        """-> (df, off, impact) or None."""
        h = h48(term)
        m = self.m
        nb = m["nb"]
        kb = key_bytes(nb)
        b = (h * nb) >> 48
        page = self.rd(m["o_dict"] + b * PAGE, PAGE)
        cnt = struct.unpack_from("<H", page, 0)[0]
        key = h.to_bytes(6, "big")[6 - kb:]
        o = 2
        for _ in range(cnt):
            w = struct.unpack_from("<I", page, o + kb)[0]
            hit = page[o:o + kb] == key
            o += kb + 4
            if w >> 24:
                if hit:
                    return (1, w & 0xFFFFFF, w >> 24)
            else:
                if hit:
                    return (w, int.from_bytes(page[o:o + 5], "little"), 0)
                o += 5
        return None

    def directory(self, df, off):
        nblk = (df + 127) // 128
        raw = self.rd(self.m["o_post"] + off, nblk * 6)
        lasts, lens = [], []
        for i in range(nblk):
            a, ln = struct.unpack_from("<IH", raw, i * 6)
            lasts.append(a)
            lens.append(ln)
        starts = [0]
        for ln in lens:
            starts.append(starts[-1] + ln)
        return lasts, lens, starts

    def single(self, df, off):
        base = self.m["o_post"] + off
        ln = struct.unpack("<H", self.rd(base, 2))[0]
        return decode_block(self.rd(base + 2, ln), df, 0)

    def full_list(self, ent):
        df, off, imp = ent
        if df == 1:
            return {off: imp}
        if df <= 128:
            return dict(zip(*self.single(df, off)))
        base = self.m["o_post"] + off
        lasts, lens, starts = self.directory(df, off)
        nblk = len(lasts)
        data = self.rd(base + nblk * 6, starts[-1])
        out = {}
        prev = 0
        for i in range(nblk):
            n = min(128, df - i * 128)
            ids, im = decode_block(data[starts[i]:starts[i + 1]], n, prev)
            prev = lasts[i]
            out.update(zip(ids, im))
        return out

    def probe(self, ent, cands):
        df, off, imp = ent
        if df == 1:
            return {off: imp} if off in cands else {}
        if df <= 128:
            full = self.full_list(ent)
            return {d: full[d] for d in cands if d in full}
        lasts, lens, starts = self.directory(df, off)
        nblk = len(lasts)
        base = self.m["o_post"] + off + nblk * 6
        need = collections.OrderedDict()
        for d in cands:
            i = bisect.bisect_left(lasts, d)
            if i < nblk:
                need[i] = 1
        out = {}
        for i in need:
            n = min(128, df - i * 128)
            ids, im = decode_block(self.rd(base + starts[i], lens[i]), n, lasts[i - 1] if i else 0)
            for d, q in zip(ids, im):
                if d in cands:
                    out[d] = q
        return out

    def doc(self, d):
        o = self.m["o_docs"] + d * DOC.size
        pg = o // PAGE
        buf = self.pages.get(pg)
        if buf is None:
            buf = self.pages[pg] = (pg * PAGE, self.rd(pg * PAGE, PAGE + DOC.size))
        return DOC.unpack_from(buf[1], o - buf[0])

    def string(self, base, n, i):
        a, b = struct.unpack("<II", self.rd(base + 4 * i, 8))
        return self.rd(base + 4 * (n + 1) + a, b - a).decode("utf-8", "surrogatepass")

    def preview(self, d):
        blk = d // PREV_N
        a, b = struct.unpack("<II", self.rd(self.m["o_poffs"] + 4 * blk, 8))
        return json.loads(pu(self.rd(self.m["o_pdata"] + a, b - a)))[d % PREV_N]


def query(index_dir, limit, q):
    load_dict(index_dir)
    words = []
    for w in TOKEN.findall(q.lower()):
        if w not in words:
            words.append(w)
    if not words:
        return
    for attempt in range(6):
        try:
            man = read_manifest(index_dir)
            segs = [Seg(index_dir, m) for m in man["segs"]]
            break
        except FileNotFoundError:            # a merge committed and removed a segment under us
            if attempt == 5:
                raise
    total = sum(s.m["ndocs"] for s in segs)
    ents = [[s.lookup(w) for w in words] for s in segs]
    dfs = [sum(e[i][0] for e in ents if e[i]) for i in range(len(words))]
    if not dfs or min(dfs) == 0:
        return
    idf = [math.log(1 + (total - d + 0.5) / (d + 0.5)) for d in dfs]
    cand = []
    for si, seg in enumerate(segs):
        es = ents[si]
        if any(e is None for e in es):
            continue
        order = sorted(range(len(words)), key=lambda i: es[i][0])
        drv = order[0]
        sc = {d: idf[drv] * q_ for d, q_ in seg.full_list(es[drv]).items()}
        for i in order[1:]:
            if not sc:
                break
            got = seg.probe(es[i], sc)
            sc = {d: s + idf[i] * got[d] for d, s in sc.items() if d in got}
        cand.extend((s, si, d) for d, s in sc.items())
    cand.sort(key=lambda x: -x[0])
    seen = set()
    out = 0
    for _, si, d in cand:
        seg = segs[si]
        sess, fid, ln, bi, _ = seg.doc(d)
        if fid in seg.dead:
            continue
        sname = seg.string(seg.m["o_sess"], seg.m["nsess"], sess)
        if sname in seen:
            continue
        seen.add(sname)
        entry = seg.string(seg.m["o_files"], seg.m["nfiles"], fid)
        prefix = entry.split("\0", 1)[-1]
        print(json.dumps({"session": sname, "id": "%s:%d:%d" % (prefix, ln, bi), "preview": seg.preview(d)}))
        out += 1
        if out >= limit:
            break


def main():
    cmd = sys.argv[1]
    if cmd in ("build", "update"):
        ingest(sys.argv[2], sys.argv[3])
    elif cmd == "remove":
        remove(sys.argv[2], sys.argv[3])
    elif cmd == "query":
        query(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    elif cmd == "check":
        read_manifest(sys.argv[2])
    else:
        sys.exit("unknown command")


if __name__ == "__main__":
    main()
