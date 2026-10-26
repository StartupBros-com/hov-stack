import json, os, re, shutil, subprocess, sys

BASE = "/tmp/hv-correct-2026-10-07"
J = BASE + "/judge-one"


def sh(cmd, cwd):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr)


def rd(p):
    return open(p).read()


def wr(p, s):
    open(p, "w").write(s)


def restore(d):
    sh("git checkout -- .", d)
    sh("git clean -fd", d)


def p1(d):
    m = d + "/src/ledgerline/models.py"
    s = rd(m)
    s2 = s.replace('"disputed")', '"disputed", "refunded")', 1)
    assert s != s2
    wr(m, s2)
    code, out = sh(
        "PYTHONPATH=src python3 -c \"from ledgerline import api, export, models;"
        "from ledgerline.storage import repo;"
        "api.create_invoice('A-1','x',[{'description':'w','quantity':1,'unit_price_cents':100}]);"
        "print(api.set_status('A-1','refunded')['status']); print(list(export.status_summary()))\"",
        d)
    return "single source; runtime: " + out.strip().replace("\n", " | ")[:200], None


def mc(d):
    return sh("make check", d)


def p2(d):
    f = d + "/src/ledgerline/pricing.py"
    s = rd(f)
    s += "\n\ndef late_fee_cents(total, days_late):\n    return int(total * 0.015 * days_late)\n"
    s = s.replace("    return sub + tax_cents(sub, invoice.tax_bps)",
                  "    t = sub + tax_cents(sub, invoice.tax_bps)\n    if invoice.status == 'overdue':\n        t += late_fee_cents(t, 0)\n    return t")
    wr(f, s)
    return mc(d)


def p3(d):
    f = d + "/src/ledgerline/api.py"
    s = rd(f)
    s = s.replace("from ledgerline.storage import repo", "from ledgerline.storage import _db, repo", 1)
    s += "\n\ndef count_invoices():\n    return len(_db.all_rows('invoices'))\n"
    wr(f, s)
    return mc(d)


def p4(d):
    f = d + "/src/ledgerline/export.py"
    s = rd(f)
    s += '\n\nPAID_STATES = ("draft", "sent", "paid", "overdue", "void", "disputed")\n\n\ndef paid_summary():\n    return {k: v for k, v in status_summary().items() if k in PAID_STATES}\n'
    wr(f, s)
    return mc(d)


def p5(d):
    f = d + "/src/ledgerline/export.py"
    s = rd(f)
    # replace the call-site formatting of the total column
    s2 = s.replace("format_cents(pricing.total_cents(inv))", '"%.2f" % (pricing.total_cents(inv) / 100)')
    assert s != s2
    wr(f, s2)
    return mc(d)


if __name__ == "__main__":
    r = sys.argv[1]
    d = J + "/" + r
    if os.path.exists(d):
        shutil.rmtree(d)
    shutil.copytree(BASE + "/runs/" + r + "/repo", d, symlinks=True)
    restore(d)
    code, out = mc(d)
    res = {"base_rc": code, "base_tail": out.strip().splitlines()[-3:]}
    for name, fn in [("P1", p1), ("P2", p2), ("P3", p3), ("P4", p4), ("P5", p5)]:
        try:
            rr = fn(d)
            if name == "P1":
                res[name] = rr[0]
            else:
                c, o = rr
                res[name] = {"rc": c, "out": o.strip()[-500:]}
        except Exception as e:
            res[name] = {"err": repr(e)}
        restore(d)
    print(json.dumps({r: res}, indent=1))
