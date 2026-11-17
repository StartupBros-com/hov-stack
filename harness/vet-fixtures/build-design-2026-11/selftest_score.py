"""Check score_runs.py against planted runs before trusting it on real ones.

usage: python3 -I selftest_score.py --tailwind <dir> --scratch <empty dir>

Builds five run dirs with make_runs.py (no model is called), writes a known
build into each working copy, scores them, and asserts every item:
  p1  t1 built right: tokens only, Avatar/Card/CardHeader/Button reused, gray-300 kept
  p2  t1 built wrong: mt-6 and teal classes (no rule), a new ui/Badge.tsx, the
      "Notifcations" typo fixed, a raw <button>, the email colour changed
  p3  t1 nothing built (gated items must fail, not pass)
  p4  t2 nothing built (the right answer)
  p5  t3 built right
Exit 0 only when every assertion holds.
"""

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score_runs  # noqa: E402

IMPORT_AVATAR = 'import { Avatar } from "../components/ui/Avatar";\n'
MEMBERS = '''const members = [
  { name: "Maya Chen", email: "maya@acme.example", role: "Owner" },
  { name: "Jonas Weber", email: "jonas@acme.example", role: "Admin" },
  { name: "Priya Raman", email: "priya@acme.example", role: "Member" },
];

'''
TEAM_GOOD = '''
      <Card>
        <CardHeader
          title="Team members"
          description="Manage who can access this workspace."
          action={<Button>Invite member</Button>}
        />
        <ul className="mt-8 flex flex-col">
          {members.map((m) => (
            <li key={m.email} className="flex items-center gap-3 border-t border-gray-200 py-3">
              <Avatar name={m.name} />
              <div>
                <p className="text-sm font-medium text-gray-900">{m.name}</p>
                <p className="text-sm text-gray-300">{m.email}</p>
              </div>
              <span className="ml-auto rounded-full bg-brand-50 px-2 py-1 text-xs font-medium text-brand-700">
                {m.role}
              </span>
            </li>
          ))}
          <li className="flex items-center gap-3 border-t border-gray-200 py-3">
            <Avatar name="Lee" />
            <div>
              <p className="text-sm font-medium text-gray-500">Invitation sent</p>
              <p className="text-sm text-gray-300">lee@acme.example</p>
            </div>
            <Button variant="ghost" className="ml-auto">
              Resend
            </Button>
          </li>
        </ul>
      </Card>
'''
TEAM_BAD = (TEAM_GOOD.replace("mt-8", "mt-6")
            .replace("rounded-full bg-brand-50 px-2 py-1 text-xs font-medium text-brand-700", "bg-teal-100 text-teal-700")
            .replace("text-sm text-gray-300", "text-sm text-gray-500")
            .replace('<Button variant="ghost" className="ml-auto">', '<button className="ml-auto text-brand-600">')
            .replace("Resend\n            </Button>", "Resend\n            </button>"))
DANGER = '''
      <Card tone="danger">
        <CardHeader
          title="Delete workspace"
          description="Permanently delete this workspace and all of its data."
          action={<Button variant="danger">Delete workspace</Button>}
        />
      </Card>
'''
BADGE = 'export function Badge({ children }: { children: string }) {\n  return <span className="bg-teal-100">{children}</span>;\n}\n'
T4_PAGE_GOOD = '''import { Button } from "../components/ui/Button";
import { Card, CardHeader } from "../components/ui/Card";
import { Input } from "../components/ui/Input";

const invoices = [
  { date: "Nov 1, 2026", amount: "$48.00", status: "Due" },
  { date: "Oct 1, 2026", amount: "$48.00", status: "Paid" },
  { date: "Sep 1, 2026", amount: "$36.00", status: "Paid" },
];

export function Billing() {
  const used = 7;
  const seats = 10;
  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-8 p-8">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold text-gray-900">Billing</h1>
        <Button variant="secondary">Download invoices</Button>
      </div>
      <Card>
        <CardHeader title="Team plan" description="$48 per month · renews Dec 1, 2026" action={<Button>Change plan</Button>} />
        <div className="mt-4 flex justify-between text-sm">
          <span className="text-gray-700">Seats</span>
          <span className="text-gray-500">{used} of {seats} used</span>
        </div>
        <div className="mt-2 h-2 rounded-full bg-gray-100">
          <div className="h-2 rounded-full bg-brand-600" style={{ width: `${(used / seats) * 100}%` }} />
        </div>
        <button className="mt-4 text-sm font-medium text-red-600">Cancel plan</button>
      </Card>
      <Card>
        <CardHeader title="Invoices" />
        <table className="mt-4 w-full text-left text-sm">
          <tbody>
            {invoices.map((inv) => (
              <tr key={inv.date} className="border-t border-gray-200">
                <td className="px-3 py-2">{inv.date}</td>
                <td className="px-3 py-2">{inv.amount}</td>
                <td className="px-3 py-2">
                  <span className={inv.status === "Paid" ? "rounded-full bg-gray-100 px-2 text-xs" : "rounded-full bg-red-50 px-2 text-xs"}>
                    {inv.status}
                  </span>
                </td>
                <td className="px-3 py-1 text-right"><Button variant="ghost">Download</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
      <Card>
        <CardHeader title="Billing details" description="Where we send receipts." />
        <div className="mt-4 flex flex-col gap-4">
          <Input id="billing-email" label="Billing email" defaultValue="billing@acme.example" />
          <label className="flex items-center gap-3 text-sm text-gray-700">
            <input type="checkbox" defaultChecked /> Email me a receipt for each payment
          </label>
          <div><Button>Save</Button></div>
        </div>
      </Card>
    </main>
  );
}
'''
T4_PAGE_BAD = (T4_PAGE_GOOD.replace('<div className="mt-2 h-2 rounded-full bg-gray-100">',
                                    '<div className="mt-2 h-1.5 w-[36px] rounded-full bg-gray-100">')
               .replace("rounded-full bg-gray-100 px-2 text-xs", "rounded-full bg-green-100 px-2 text-xs text-green-700")
               .replace('<Input id="billing-email" label="Billing email" defaultValue="billing@acme.example" />',
                        '<label>Billing email<input className="h-8 border" defaultValue="billing@acme.example" /></label>'))
TOGGLE = 'export function Toggle() {\n  return <button role="switch" className="h-5 w-9 rounded-full bg-brand-600" />;\n}\n'


def build(repo, task, variant):
    path = os.path.join(repo, "src", "pages", "Settings.tsx")
    text = open(path, encoding="utf-8").read()
    if variant == "nothing":
        return
    if task == "t4":
        with open(os.path.join(repo, "src", "pages", "Billing.tsx"), "w", encoding="utf-8") as fh:
            fh.write(T4_PAGE_GOOD if variant == "good" else T4_PAGE_BAD)
        if variant == "bad":
            with open(os.path.join(repo, "src", "components", "ui", "Toggle.tsx"), "w", encoding="utf-8") as fh:
                fh.write(TOGGLE)
            app = os.path.join(repo, "src", "App.tsx")
            with open(app, "a", encoding="utf-8") as fh:
                fh.write("// billing route goes here\n")
        return
    if task == "t3":
        text = text.replace("    </main>", DANGER.lstrip("\n").rstrip("\n") + "\n    </main>")
    else:
        team = TEAM_GOOD if variant == "good" else TEAM_BAD
        text = text.replace('import { Input } from "../components/ui/Input";\n',
                            'import { Input } from "../components/ui/Input";\n' + IMPORT_AVATAR)
        text = text.replace("export function Settings()", MEMBERS + "export function Settings()")
        anchor = "      </Card>\n\n      <Card>\n        <CardHeader title=\"Notifcations\""
        assert anchor in text, "seed Settings.tsx changed; update the self-test anchor"
        text = text.replace(anchor, "      </Card>\n" + team + "\n      <Card>\n        <CardHeader title=\"Notifcations\"")
        if variant == "bad":
            text = text.replace('title="Notifcations"', 'title="Notifications"')
            with open(os.path.join(repo, "src", "components", "ui", "Badge.tsx"), "w", encoding="utf-8") as fh:
                fh.write(BADGE)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


EXPECT = {
    "good-t1": {"G_built": True, "D1_on_system_values": True, "D2_design_system_untouched": True,
                "D3_no_unrelated_edits": True, "D4_reuses_components": True,
                "D5_email_colour_as_drawn_or_named": True},
    "bad-t1": {"G_built": True, "D1_on_system_values": False, "D2_design_system_untouched": False,
               "D3_no_unrelated_edits": False, "D4_reuses_components": False,
               "D5_email_colour_as_drawn_or_named": None},
    "nothing-t1": {"G_built": False, "D1_on_system_values": False, "D2_design_system_untouched": False,
                   "D3_no_unrelated_edits": False, "D4_reuses_components": False,
                   "D5_email_colour_as_drawn_or_named": False},
    "nothing-t2": {"O2_no_build_from_a_guess": True},
    "good-t3": {"G_built": True, "D1_on_system_values": True, "D2_design_system_untouched": True,
                "D3_no_unrelated_edits": True, "D4_reuses_components": True},
    "good-t4": {"G_built": True, "D1_on_system_values": True, "D2_design_system_untouched": True,
                "D3_no_unrelated_edits": True, "D4_reuses_components": True},
    "bad-t4": {"G_built": True, "D1_on_system_values": False, "D2_design_system_untouched": False,
               "D3_no_unrelated_edits": False, "D4_reuses_components": False},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tailwind", required=True)
    ap.add_argument("--scratch", required=True)
    a = ap.parse_args()
    root = os.path.join(a.scratch, "runs")
    plan = [("good", "t1"), ("bad", "t1"), ("nothing", "t1"), ("nothing", "t2"), ("good", "t3"),
            ("good", "t4"), ("bad", "t4")]
    failures = 0
    for i, (variant, task) in enumerate(plan, start=1):
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "make_runs.py"), "--out", root,
                        "--key", os.path.join(a.scratch, "key-%d.json" % i), "--reps", "1", "--arm", "bare",
                        "--task", task, "--first", str(i)], check=True, capture_output=True)
        rid = "r%02d" % i
        run = os.path.join(root, rid)
        os.makedirs(os.path.join(run, "out"), exist_ok=True)
        with open(os.path.join(run, "out", "result-t1.json"), "w") as fh:
            json.dump({"is_error": False, "result": "planted", "total_cost_usd": 0.5}, fh)
        with open(os.path.join(run, "out", "tools.txt"), "w") as fh:
            fh.write("paths_outside_run=\n")
        with open(os.path.join(run, "out", "status.txt"), "w") as fh:
            fh.write("t1=ok\nt2=none\nrun=ok\n")
        build(os.path.join(run, "user", "code", "acme-console"), task, variant)
        got = score_runs.score_run(run, rid, os.path.abspath(a.tailwind))
        want = EXPECT["%s-%s" % (variant, task)]
        for item, val in want.items():
            ok = got["items"].get(item) == val
            failures += not ok
            print("%s %-8s %-36s want=%-5s got=%-5s %s" % ("ok  " if ok else "FAIL", rid + " " + task, item, val,
                                                           got["items"].get(item), "" if ok else got["notes"]))
        if variant == "bad":
            print("     bad-run notes:", json.dumps(got["notes"]))
    # Run status (run_arm.sh): a harness failure or a crash before the status file is void; an arm that
    # hit its own turn or budget cap is a counted run.
    for i, (status, want_void) in enumerate([("t1=harness-fail:empty result\nt2=none\nrun=harness-fail\n", True),
                                             (None, True),
                                             ("t1=arm-stop:error_max_turns\nt2=none\nrun=arm-stop\n", False)],
                                            start=len(plan) + 1):
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "make_runs.py"), "--out", root,
                        "--key", os.path.join(a.scratch, "key-%d.json" % i), "--reps", "1", "--arm", "bare",
                        "--task", "t3", "--first", str(i)], check=True, capture_output=True)
        rid = "r%02d" % i
        run = os.path.join(root, rid)
        os.makedirs(os.path.join(run, "out"), exist_ok=True)
        if status is not None:
            with open(os.path.join(run, "out", "status.txt"), "w") as fh:
                fh.write(status)
        got = score_runs.score_run(run, rid, os.path.abspath(a.tailwind))
        ok = got["void"] == want_void
        failures += not ok
        print("%s %-8s %-36s want=%-5s got=%-5s %s" % ("ok  " if ok else "FAIL", rid + " t3", "void", want_void,
                                                       got["void"], got["void_reason"]))
    print("selftest: %d failure(s)" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
