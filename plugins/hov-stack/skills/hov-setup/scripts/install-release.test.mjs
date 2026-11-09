import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "install-release.sh");
const scriptText = readFileSync(script, "utf8");
const offers = JSON.parse(readFileSync(join(here, "offers.json"), "utf8"));
const have = (prog) => spawnSync("sh", ["-c", `command -v ${prog}`]).status === 0;

// A fake curl: finds -o <path> and the url (last argument), copies the fixture mapped to that url.
const FAKE_CURL = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DIR/curl-calls"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) url=$1; shift ;; esac
done
src=$(awk -F'\\t' -v u="$url" '$1==u {print $2}' "$FAKE_DIR/map")
[ -n "$src" ] || { echo "fake curl: no fixture for $url" >&2; exit 22; }
cp "$src" "$out"
`;
const FAKE_SUDO = `#!/bin/sh
echo called > "$FAKE_DIR/sudo-marker"
exit 1
`;

const sha = (file) => createHash("sha256").update(readFileSync(file)).digest("hex");
const script_ver = (v, code = 0) => `#!/bin/sh\n[ "$1" = "--version" ] && { echo "${v}"; exit ${code}; }\nexit 0\n`;

function sh(cmd, cwd) {
  const r = spawnSync("sh", ["-c", cmd], { cwd, encoding: "utf8" });
  assert.equal(r.status, 0, `${cmd}\n${r.stderr}`);
}

// Builds a world: fake curl + sudo on PATH, fixture archives, a table, an empty dest.
function world(run) {
  const dir = mkdtempSync(join(tmpdir(), "hov-install-release-"));
  try {
    const bin = join(dir, "fakebin");
    const fix = join(dir, "fixtures");
    const dest = join(dir, "dest");
    mkdirSync(bin);
    mkdirSync(fix);
    writeFileSync(join(bin, "curl"), FAKE_CURL);
    writeFileSync(join(bin, "sudo"), FAKE_SUDO);
    chmodSync(join(bin, "curl"), 0o755);
    chmodSync(join(bin, "sudo"), 0o755);
    const map = [];
    const rows = [];

    // add a fixture archive; files: {relpath: content}; returns the url
    const archive = ({ tool, platform = "linux-x86_64", name, files, members, zip = false, badSha = false, version = "1.0.0" }) => {
      const stage = join(fix, `stage-${name}`);
      for (const [rel, content] of Object.entries(files)) {
        mkdirSync(dirname(join(stage, rel)), { recursive: true });
        writeFileSync(join(stage, rel), content);
        chmodSync(join(stage, rel), 0o755);
      }
      const file = join(fix, name);
      const top = [...new Set(Object.keys(files).map((f) => f.split("/")[0]))].join(" ");
      sh(zip ? `zip -qr "${file}" ${top}` : `tar -czf "${file}" ${top}`, stage);
      const url = `https://example.test/dl/${name}`;
      map.push(`${url}\t${file}`);
      rows.push([tool, version, platform, url, badSha ? "0".repeat(64) : sha(file), members.join(",")].join("|"));
      return url;
    };

    const ctx = {
      dir, bin, dest, archive,
      reset() { map.length = 0; rows.length = 0; },
      receipt: (tool) => {
        const f = join(dir, "home", ".local", "state", "hov-stack", "install-release", tool);
        return existsSync(f) ? readFileSync(f, "utf8") : null;
      },
      go(args, { platform = "linux-x86_64", extraPath = "", env = {}, cwd } = {}) {
        writeFileSync(join(dir, "map"), map.join("\n") + "\n");
        return spawnSync("bash", [script, ...args], {
          cwd,
          encoding: "utf8",
          env: {
            PATH: `${bin}:${extraPath ? extraPath + ":" : ""}${process.env.PATH}`,
            HOME: join(dir, "home"),
            FAKE_DIR: dir,
            HOV_SETUP_BIN_DIR: dest,
            HOV_SETUP_PLATFORM: platform,
            HOV_SETUP_RELEASE_TABLE: "\n" + rows.join("\n") + "\n",
            ...env,
          },
        });
      },
      files: () => (existsSync(dest) ? readdirSync(dest).sort() : []),
      curlCalls: () => (existsSync(join(dir, "curl-calls")) ? readFileSync(join(dir, "curl-calls"), "utf8") : ""),
    };
    return run(ctx);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

for (const [label, output, status, expected] of [
  ["Intel", "0", 0, "darwin-x86_64"],
  ["Rosetta", " \n\t1 \n", 0, "darwin-arm64"],
  ["failed sysctl with misleading output", "1", 1, "darwin-x86_64"],
  ["unexpected sysctl output", "2", 0, "darwin-x86_64"],
  ["malformed Rosetta output", "1 extra", 0, "darwin-x86_64"],
]) {
  test(`native macOS installer selects the ${label} archive`, () => {
    world((w) => {
      for (const platform of ["darwin-arm64", "darwin-x86_64"]) {
        w.archive({ tool: "gh", platform, name: `${platform}.tar.gz`, files: { "bin/gh": script_ver(platform) }, members: ["bin/gh"] });
      }
      writeFileSync(join(w.bin, "uname"), '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; *) exit 1 ;; esac\n');
      writeFileSync(join(w.bin, "sysctl"), `#!/bin/sh\nprintf '%s\\n' "$*" > "$FAKE_DIR/sysctl-calls"\nprintf '%s\\n' '${output}'\nexit ${status}\n`);
      chmodSync(join(w.bin, "uname"), 0o755);
      chmodSync(join(w.bin, "sysctl"), 0o755);
      const r = w.go(["gh"], { platform: "" });
      assert.equal(r.status, 0, r.stderr);
      assert.match(w.receipt("gh"), new RegExp(`^platform=${expected}$`, "m"));
      assert.match(readFileSync(join(w.dest, "gh"), "utf8"), new RegExp(expected));
      assert.equal(w.curlCalls().includes(`${expected}.tar.gz`), true);
      assert.equal(w.curlCalls().trim().split("\n").length, 1);
      assert.equal(readFileSync(join(w.dir, "sysctl-calls"), "utf8"), "-n sysctl.proc_translated\n");
    });
  });
}

test("installs, then prints installed: and on PATH: lines", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh_1.0.0.tar.gz", files: { "pkg/bin/gh": script_ver("gh version 1.0.0") }, members: ["pkg/bin/gh"] });
    const r = w.go(["gh"]);
    assert.equal(r.status, 0, r.stderr);
    const lines = r.stdout.trim().split("\n");
    assert.deepEqual(lines, [`installed: ${join(w.dest, "gh")}`, `on PATH: no (${w.dest} is not on PATH)`]);
    assert.deepEqual(w.files(), ["gh"]);
    const r2 = w.go(["gh", "--force"], { extraPath: w.dest });
    assert.equal(r2.status, 0, r2.stderr);
    assert.match(r2.stdout, /^on PATH: yes$/m);
  });
});

test("installs every member of a two-member archive under its basename", () => {
  world((w) => {
    w.archive({
      tool: "uv",
      name: "uv-x.tar.gz",
      files: { "uv-x/uv": script_ver("uv 1.0.0"), "uv-x/uvx": script_ver("uvx 1.0.0") },
      members: ["uv-x/uv", "uv-x/uvx"],
    });
    const r = w.go(["uv"]);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(w.files(), ["uv", "uvx"]);
    assert.match(r.stdout, new RegExp(`installed: ${join(w.dest, "uv")}\\ninstalled: ${join(w.dest, "uvx")}\\n`));
  });
});

test("installs from a zip archive", (t) => {
  if (!have("zip") || !have("unzip")) return t.skip("zip or unzip is not installed here");
  world((w) => {
    w.archive({ tool: "gh", name: "gh_mac.zip", zip: true, files: { "pkg/bin/gh": script_ver("gh version 1.0.0") }, members: ["pkg/bin/gh"] });
    const r = w.go(["gh"]);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(w.files(), ["gh"]);
  });
});

test("a hash mismatch exits 1, names both hashes, and installs nothing", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh_bad.tar.gz", files: { "pkg/bin/gh": script_ver("v") }, members: ["pkg/bin/gh"], badSha: true });
    const r = w.go(["gh"]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /expected 0{64}/);
    assert.match(r.stderr, /got\s+[0-9a-f]{64}/);
    assert.deepEqual(w.files(), []);
  });
});

test("a listed member missing from the archive exits 1 and installs nothing", () => {
  world((w) => {
    w.archive({ tool: "uv", name: "uv-short.tar.gz", files: { "uv-x/uv": script_ver("v") }, members: ["uv-x/uv", "uv-x/uvx"] });
    const r = w.go(["uv"]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /uv-x\/uvx is not in/);
    assert.deepEqual(w.files(), []);
  });
});

test("an unknown tool exits 3", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh.tar.gz", files: { "pkg/bin/gh": script_ver("v") }, members: ["pkg/bin/gh"] });
    const r = w.go(["nope"]);
    assert.equal(r.status, 3);
    assert.match(r.stderr, /unknown tool 'nope'/);
    assert.equal(w.curlCalls(), "");
  });
});

test("a tool without this platform exits 3 and names the platforms it has", () => {
  world((w) => {
    w.archive({ tool: "gh", platform: "linux-aarch64", name: "gh.tar.gz", files: { "pkg/bin/gh": script_ver("v") }, members: ["pkg/bin/gh"] });
    const r = w.go(["gh"], { platform: "darwin-arm64" });
    assert.equal(r.status, 3);
    assert.match(r.stderr, /no release for darwin-arm64/);
    assert.match(r.stderr, /linux-aarch64/);
    assert.deepEqual(w.files(), []);
  });
});

test("bad usage exits 2", () => {
  world((w) => {
    assert.equal(w.go([]).status, 2);
    assert.equal(w.go(["gh", "uv"]).status, 2);
    assert.equal(w.go(["gh", "--bogus"]).status, 2);
    assert.equal(w.curlCalls(), "");
  });
});

test("an existing file exits 4 with dest unchanged; --force replaces it", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh.tar.gz", files: { "pkg/bin/gh": script_ver("gh version NEW") }, members: ["pkg/bin/gh"] });
    mkdirSync(w.dest);
    writeFileSync(join(w.dest, "gh"), "#!/bin/sh\necho OLD\n");
    chmodSync(join(w.dest, "gh"), 0o755);
    const r = w.go(["gh"]);
    assert.equal(r.status, 4);
    assert.equal(readFileSync(join(w.dest, "gh"), "utf8"), "#!/bin/sh\necho OLD\n");
    assert.deepEqual(w.files(), ["gh"]);
    assert.equal(w.curlCalls(), "", "nothing is downloaded when the target exists");
    const f = w.go(["gh", "--force"]);
    assert.equal(f.status, 0, f.stderr);
    assert.match(readFileSync(join(w.dest, "gh"), "utf8"), /gh version NEW/);
  });
});

test("one existing member of two blocks the whole install (exit 4, nothing added)", () => {
  world((w) => {
    w.archive({ tool: "uv", name: "uv.tar.gz", files: { "uv-x/uv": script_ver("v"), "uv-x/uvx": script_ver("v") }, members: ["uv-x/uv", "uv-x/uvx"] });
    mkdirSync(w.dest);
    writeFileSync(join(w.dest, "uvx"), "old");
    assert.equal(w.go(["uv"]).status, 4);
    assert.deepEqual(w.files(), ["uvx"]);
  });
});

test("a member whose --version fails exits 1 and leaves nothing it installed", () => {
  world((w) => {
    w.archive({
      tool: "uv",
      name: "uv.tar.gz",
      files: { "uv-x/uv": script_ver("broken", 1), "uv-x/uvx": script_ver("uvx 1.0.0") },
      members: ["uv-x/uv", "uv-x/uvx"],
    });
    const r = w.go(["uv"]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /--version failed/);
    assert.deepEqual(w.files(), []);
    assert.doesNotMatch(r.stdout, /installed:/);
  });
});

test("sudo is never called", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh.tar.gz", files: { "pkg/bin/gh": script_ver("v") }, members: ["pkg/bin/gh"] });
    assert.equal(w.go(["gh"]).status, 0);
    assert.equal(w.go(["gh"]).status, 4);
    assert.equal(w.go(["gh", "--force"]).status, 0);
    assert.equal(existsSync(join(w.dir, "sudo-marker")), false);
    assert.doesNotMatch(scriptText.replace(/^\s*#.*$/gm, ""), /\bsudo\b/);
  });
});

test("the download uses curl with the url's archive name and the retry flags", () => {
  world((w) => {
    const url = w.archive({ tool: "gh", name: "gh_9.9.9_linux_amd64.tar.gz", files: { "pkg/bin/gh": script_ver("v") }, members: ["pkg/bin/gh"] });
    assert.equal(w.go(["gh"]).status, 0);
    const calls = w.curlCalls().trim().split("\n");
    assert.equal(calls.length, 1);
    assert.match(calls[0], /^-fsSL --retry 2 --connect-timeout 15 -o \S+\/gh_9\.9\.9_linux_amd64\.tar\.gz /);
    assert.ok(calls[0].endsWith(` ${url}`), calls[0]);
  });
});

test("the work directory is removed and no temp file is left in dest", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh.tar.gz", files: { "pkg/bin/gh": script_ver("v") }, members: ["pkg/bin/gh"] });
    const tmp = join(w.dir, "tmp");
    mkdirSync(tmp);
    assert.equal(w.go(["gh"], { env: { TMPDIR: tmp } }).status, 0);
    assert.deepEqual(readdirSync(tmp), []);
    assert.deepEqual(w.files(), ["gh"]);
  });
});

// ---- the real table: parsed from the file, never executed ------------------------------

function realRows() {
  const rows = [];
  for (const line of scriptText.split("\n")) {
    if (!/^[a-z]+\|[^|]*\|[^|]*\|https?:/.test(line)) continue;
    const [tool, version, platform, url, sha256, members] = line.split("|");
    rows.push({ tool, version, platform, url, sha256, members });
  }
  return rows;
}

test("the real table has well-formed rows", () => {
  const rows = realRows();
  assert.equal(rows.length, 15);
  assert.deepEqual(rows.filter((r) => r.platform === "darwin-x86_64").map((r) => r.tool).sort(), ["gh", "jsm", "uv"]);
  const platforms = ["darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-aarch64"];
  const seen = new Set();
  for (const r of rows) {
    const id = `${r.tool}/${r.platform}`;
    assert.ok(!seen.has(id), `duplicate row ${id}`);
    seen.add(id);
    assert.ok(r.url.startsWith("https://") && r.url.length >= 40, `${id}: url`);
    assert.match(r.sha256, /^[0-9a-f]{64}$/, `${id}: sha256`);
    assert.ok(platforms.includes(r.platform), `${id}: platform`);
    assert.ok(r.members.split(",").every((m) => m.length > 0) && r.members.length > 0, `${id}: members`);
    assert.match(r.url, /\.(tar\.gz|tgz|zip)$/, `${id}: archive type`);
  }
});

test("every install-release.sh install line in offers.json has a table row per platform", () => {
  const rows = realRows();
  const entries = [...offers.offers, ...offers.helpers];
  let checked = 0;
  for (const e of entries) {
    for (const [platform, line] of Object.entries(e.install ?? {})) {
      const m = line.match(/install-release\.sh"? (\S+)/);
      if (!m) continue;
      checked++;
      assert.ok(
        rows.some((r) => r.tool === m[1] && r.platform === platform),
        `${e.name}: no table row for ${m[1]} on ${platform}`,
      );
    }
  }
  assert.ok(checked >= 15, `expected at least 15 install-release lines, saw ${checked}`);
});

test("the script's header documents both env vars, the exit codes and the bash 3.2 rule", () => {
  const header = scriptText.split("\nset -euo pipefail")[0];
  for (const needle of ["HOV_SETUP_BIN_DIR", "HOV_SETUP_PLATFORM", "HOV_SETUP_RELEASE_TABLE", "HOV_SETUP_STATE_DIR", "--update", "install record", "consumer", "gate", "defect", "delete-when", "3.2"]) {
    assert.ok(header.includes(needle), `header lacks ${needle}`);
  }
});

test("a later member failing to install removes the earlier member this run moved into place", (t) => {
  if (!existsSync("/usr/bin/install")) return t.skip("no /usr/bin/install");
  world((w) => {
    w.archive({
      tool: "uv",
      name: "uv.tar.gz",
      files: { "uv-x/uv": script_ver("uv 1.0.0"), "uv-x/uvx": script_ver("uvx 1.0.0") },
      members: ["uv-x/uv", "uv-x/uvx"],
    });
    // fake install: refuses to write the second member's temp file, otherwise defers to the real one
    writeFileSync(join(w.bin, "install"), `#!/bin/sh\nfor a in "$@"; do case "$a" in */.hov-setup.*/uvx) exit 1 ;; esac; done\nexec /usr/bin/install "$@"\n`);
    chmodSync(join(w.bin, "install"), 0o755);
    const r = w.go(["uv"]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /could not write/);
    assert.deepEqual(w.files(), []);
    assert.doesNotMatch(r.stdout, /installed:/);
  });
});

test("a relative HOV_SETUP_BIN_DIR still prints absolute installed: paths", () => {
  world((w) => {
    w.archive({ tool: "gh", name: "gh_1.0.0.tar.gz", files: { "pkg/bin/gh": script_ver("gh version 1.0.0") }, members: ["pkg/bin/gh"] });
    const r = w.go(["gh"], { cwd: w.dir, env: { HOV_SETUP_BIN_DIR: "reldest" } });
    assert.equal(r.status, 0, r.stderr);
    const line = r.stdout.split("\n").find((l) => l.startsWith("installed: "));
    assert.match(line, /^installed: \//);
    assert.ok(line.endsWith("/reldest/gh"), line);
    assert.ok(existsSync(join(w.dir, "reldest", "gh")));
  });
});

test("a later member failing to move into place removes the earlier member this run moved", () => {
  world((w) => {
    w.archive({
      tool: "uv",
      name: "uv.tar.gz",
      files: { "uv-x/uv": script_ver("uv 1.0.0"), "uv-x/uvx": script_ver("uvx 1.0.0") },
      members: ["uv-x/uv", "uv-x/uvx"],
    });
    // fake mv: refuses to put the second member in its final place, otherwise defers to the real one
    writeFileSync(join(w.bin, "mv"), `#!/bin/sh\nfor a in "$@"; do case "$a" in */dest/uvx) exit 1 ;; esac; done\nexec /bin/mv "$@"\n`);
    chmodSync(join(w.bin, "mv"), 0o755);
    const r = w.go(["uv"]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /could not move uvx/);
    assert.deepEqual(w.files(), []);
    assert.equal(w.receipt("uv"), null);
  });
});

// ---- verify before swap, the install record, --update -----------------------------------

const GOOD = (v) => ({ tool: "gh", name: `gh_${v}.tar.gz`, version: v, files: { "pkg/bin/gh": script_ver(`gh version ${v}`) }, members: ["pkg/bin/gh"] });

test("a failed --version check on a --force reinstall leaves the previous copy and its record untouched", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    const before = readFileSync(join(w.dest, "gh"), "utf8");
    const rec = w.receipt("gh");
    w.reset();
    w.archive({ ...GOOD("2.0.0"), files: { "pkg/bin/gh": script_ver("broken", 1) } });
    const r = w.go(["gh", "--force"]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /--version failed/);
    assert.equal(readFileSync(join(w.dest, "gh"), "utf8"), before, "the old copy is still there");
    assert.equal(w.receipt("gh"), rec, "the record is unchanged");
    assert.deepEqual(w.files(), ["gh"], "no staging directory is left behind");
  });
});

test("a failed --version check on a first install writes no record", () => {
  world((w) => {
    w.archive({ ...GOOD("1.0.0"), files: { "pkg/bin/gh": script_ver("broken", 1) } });
    assert.equal(w.go(["gh"]).status, 1);
    assert.equal(w.receipt("gh"), null);
    assert.deepEqual(w.files(), []);
  });
});

test("the record has version, platform and one sha256 line per installed file", () => {
  world((w) => {
    w.archive({
      tool: "uv",
      name: "uv.tar.gz",
      version: "1.2.3",
      files: { "uv-x/uv": script_ver("uv 1.2.3"), "uv-x/uvx": script_ver("uvx 1.2.3") },
      members: ["uv-x/uv", "uv-x/uvx"],
    });
    assert.equal(w.go(["uv"]).status, 0);
    const lines = w.receipt("uv").trim().split("\n");
    assert.deepEqual(lines, [
      "version=1.2.3",
      "platform=linux-x86_64",
      `file=${join(w.dest, "uv")} ${sha(join(w.dest, "uv"))}`,
      `file=${join(w.dest, "uvx")} ${sha(join(w.dest, "uvx"))}`,
    ]);
    const stateDir = join(w.dir, "home", ".local", "state", "hov-stack", "install-release");
    assert.deepEqual(readdirSync(stateDir), ["uv"], "no temp file is left next to the record");
  });
});

test("HOV_SETUP_STATE_DIR moves the record", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    const state = join(w.dir, "elsewhere");
    assert.equal(w.go(["gh"], { env: { HOV_SETUP_STATE_DIR: state } }).status, 0);
    assert.ok(existsSync(join(state, "gh")));
    assert.equal(w.receipt("gh"), null);
  });
});

test("--update with --force is a usage error", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh", "--update", "--force"]).status, 2);
    assert.equal(w.curlCalls(), "");
  });
});

test("--update with no record and nothing installed exits 5 and says so", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.equal(r.stdout.trim(), "gh: not installed here; nothing to update");
    assert.equal(w.curlCalls(), "");
    assert.deepEqual(w.files(), []);
  });
});

test("--update with no record but a copy at the target exits 5 and leaves it alone", () => {
  world((w) => {
    w.archive(GOOD("2.0.0"));
    mkdirSync(w.dest);
    writeFileSync(join(w.dest, "gh"), "#!/bin/sh\necho OTHER\n");
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.match(r.stdout, /gh: .*\/gh has no hov-stack install record/);
    assert.match(r.stdout, /install-release\.sh gh --force/);
    assert.equal(readFileSync(join(w.dest, "gh"), "utf8"), "#!/bin/sh\necho OTHER\n");
    assert.equal(w.curlCalls(), "");
  });
});

test("--update exits 5 when a recorded file was removed", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    rmSync(join(w.dest, "gh"));
    w.reset();
    w.archive(GOOD("2.0.0"));
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.match(r.stdout, /was removed since hov-stack installed it/);
    assert.deepEqual(w.files(), []);
  });
});

test("--update exits 5 when a recorded file's sha256 changed, and downloads nothing", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    const edited = script_ver("gh hand-edited");
    writeFileSync(join(w.dest, "gh"), edited);
    const calls = w.curlCalls();
    w.reset();
    w.archive(GOOD("2.0.0"));
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.match(r.stdout, /changed since hov-stack installed it; nothing changed/);
    assert.equal(readFileSync(join(w.dest, "gh"), "utf8"), edited);
    assert.equal(w.curlCalls(), calls, "no new download");
  });
});

test("--update when the recorded version is the pin exits 0 without downloading", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    const calls = w.curlCalls();
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), "gh: 1.0.0, current");
    assert.equal(w.curlCalls(), calls, "no new download");
  });
});

test("--update when the pin moved reinstalls, prints old -> new and rewrites the record", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    w.reset();
    w.archive(GOOD("2.0.0"));
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), "gh: 1.0.0 -> 2.0.0");
    assert.match(readFileSync(join(w.dest, "gh"), "utf8"), /gh version 2\.0\.0/);
    const rec = w.receipt("gh");
    assert.match(rec, /^version=2\.0\.0$/m);
    assert.ok(rec.includes(`file=${join(w.dest, "gh")} ${sha(join(w.dest, "gh"))}`));
    assert.deepEqual(w.files(), ["gh"]);
  });
});

test("--update with a new release whose --version fails keeps the old copy and record", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    const before = readFileSync(join(w.dest, "gh"), "utf8");
    const rec = w.receipt("gh");
    w.reset();
    w.archive({ ...GOOD("2.0.0"), files: { "pkg/bin/gh": script_ver("broken", 1) } });
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 1);
    assert.equal(readFileSync(join(w.dest, "gh"), "utf8"), before);
    assert.equal(w.receipt("gh"), rec);
    assert.deepEqual(w.files(), ["gh"]);
  });
});

test("--update leaves alone a file the new release adds if the record does not cover it", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    w.reset();
    w.archive({
      tool: "gh", name: "gh2.tar.gz", version: "2.0.0",
      files: { "pkg/bin/gh": script_ver("gh version 2.0.0"), "pkg/bin/ghx": script_ver("ghx") },
      members: ["pkg/bin/gh", "pkg/bin/ghx"],
    });
    writeFileSync(join(w.dest, "ghx"), "mine");
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.match(r.stdout, /ghx is not in hov-stack's install record/);
    assert.equal(readFileSync(join(w.dest, "ghx"), "utf8"), "mine");
    assert.match(readFileSync(join(w.dest, "gh"), "utf8"), /gh version 1\.0\.0/);
  });
});

// ---- a failed swap puts the previous copy back; never backwards; self-updating tools --------

const UV = (v) => ({
  tool: "uv", name: `uv_${v}.tar.gz`, version: v,
  files: { "uv-x/uv": script_ver(`uv ${v}`), "uv-x/uvx": script_ver(`uvx ${v}`) },
  members: ["uv-x/uv", "uv-x/uvx"],
});
// fake mv: refuses to move the new uvx out of the stage directory, otherwise defers to the
// real one (so moving the previous uvx aside, and back, still works)
const REFUSE_NEW_UVX = `#!/bin/sh\nfor a in "$@"; do case "$a" in */.hov-setup.*/uvx) exit 1 ;; esac; done\nexec /bin/mv "$@"\n`;

for (const mode of ["--force", "--update"]) {
  test(`a ${mode} that fails mid-swap puts both previous members and their record back`, () => {
    world((w) => {
      w.archive(UV("1.0.0"));
      assert.equal(w.go(["uv"]).status, 0);
      const before = { uv: readFileSync(join(w.dest, "uv"), "utf8"), uvx: readFileSync(join(w.dest, "uvx"), "utf8") };
      const rec = w.receipt("uv");
      w.reset();
      w.archive(UV("2.0.0"));
      writeFileSync(join(w.bin, "mv"), REFUSE_NEW_UVX);
      chmodSync(join(w.bin, "mv"), 0o755);
      const r = w.go(["uv", mode]);
      assert.equal(r.status, 1);
      assert.match(r.stderr, /could not move uvx/);
      assert.equal(readFileSync(join(w.dest, "uv"), "utf8"), before.uv, "the previous uv is back");
      assert.equal(readFileSync(join(w.dest, "uvx"), "utf8"), before.uvx, "the previous uvx is back");
      assert.equal(w.receipt("uv"), rec, "the previous record stands");
      assert.deepEqual(w.files(), ["uv", "uvx"], "no stage directory is left behind");
      // and the record still matches, so the next --update can go on
      rmSync(join(w.bin, "mv"));
      const again = w.go(["uv", "--update"]);
      assert.equal(again.status, 0, again.stderr + again.stdout);
      assert.equal(again.stdout.trim(), "uv: 1.0.0 -> 2.0.0");
    });
  });
}

test("--update never moves a pin backwards: a recorded version newer than the pin exits 5", () => {
  world((w) => {
    w.archive(GOOD("2.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    const calls = w.curlCalls();
    w.reset();
    w.archive(GOOD("1.9.9"));
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.equal(r.stdout.trim(), "gh: 2.0.0 is newer than the 1.9.9 this checkout pins; nothing changed");
    assert.match(readFileSync(join(w.dest, "gh"), "utf8"), /gh version 2\.0\.0/);
    assert.equal(w.curlCalls(), calls, "no new download");
  });
});

test("--update compares versions by number, not by text (0.10.0 is newer than 0.9.9)", () => {
  world((w) => {
    w.archive(GOOD("0.10.0"));
    assert.equal(w.go(["gh"]).status, 0);
    w.reset();
    w.archive(GOOD("0.9.9"));
    const back = w.go(["gh", "--update"]);
    assert.equal(back.status, 5, "0.9.9 is older than 0.10.0");
    assert.match(back.stdout, /0\.10\.0 is newer than the 0\.9\.9/);
  });
  world((w) => {
    w.archive(GOOD("0.9.9"));
    assert.equal(w.go(["gh"]).status, 0);
    w.reset();
    w.archive(GOOD("0.10.0"));
    const fwd = w.go(["gh", "--update"]);
    assert.equal(fwd.status, 0, fwd.stderr + fwd.stdout);
    assert.equal(fwd.stdout.trim(), "gh: 0.9.9 -> 0.10.0");
  });
});

for (const [tool, hint] of [
  ["jsm", "changed since hov-stack installed it, most likely by jsm's own auto-update; nothing changed (jsm update updates it; install-release.sh jsm --force puts the pinned copy back)"],
  ["cass", "changed since hov-stack installed it, possibly by cass upgrade; nothing changed (cass upgrade updates it; install-release.sh cass --force puts the pinned copy back)"],
]) {
  test(`--update on a ${tool} that changed names ${tool}'s own updater and leaves it alone`, () => {
    world((w) => {
      const T = (v) => ({ tool, name: `${tool}_${v}.tar.gz`, version: v, files: { [tool]: script_ver(`${tool} ${v}`) }, members: [tool] });
      w.archive(T("1.0.0"));
      assert.equal(w.go([tool]).status, 0);
      const selfUpdated = script_ver(`${tool} 1.0.1`);
      writeFileSync(join(w.dest, tool), selfUpdated);
      w.reset();
      w.archive(T("2.0.0"));
      const r = w.go([tool, "--update"]);
      assert.equal(r.status, 5);
      assert.equal(r.stdout.trim(), `${tool}: ${join(w.dest, tool)} ${hint}`);
      assert.equal(readFileSync(join(w.dest, tool), "utf8"), selfUpdated);
    });
  });
}

test("--update exits 5 when a recorded file is now a symlink, and leaves it", () => {
  world((w) => {
    w.archive(GOOD("1.0.0"));
    assert.equal(w.go(["gh"]).status, 0);
    const elsewhere = join(w.dir, "gh-elsewhere");
    writeFileSync(elsewhere, readFileSync(join(w.dest, "gh")));
    rmSync(join(w.dest, "gh"));
    symlinkSync(elsewhere, join(w.dest, "gh"));
    w.reset();
    w.archive(GOOD("2.0.0"));
    const r = w.go(["gh", "--update"]);
    assert.equal(r.status, 5);
    assert.equal(r.stdout.trim(), `gh: ${join(w.dest, "gh")} is no longer the file hov-stack installed (now a symlink or not a regular file); nothing changed (install-release.sh gh --force replaces it)`);
    assert.match(readFileSync(join(w.dest, "gh"), "utf8"), /gh version 1\.0\.0/);
  });
});

