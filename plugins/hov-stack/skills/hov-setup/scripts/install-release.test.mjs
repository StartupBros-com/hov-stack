import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
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
    const archive = ({ tool, platform = "linux-x86_64", name, files, members, zip = false, badSha = false }) => {
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
      rows.push([tool, "1.0.0", platform, url, badSha ? "0".repeat(64) : sha(file), members.join(",")].join("|"));
      return url;
    };

    const ctx = {
      dir, bin, dest, archive,
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
  assert.equal(rows.length, 12);
  const platforms = ["darwin-arm64", "linux-x86_64", "linux-aarch64"];
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
  assert.ok(checked >= 12, `expected at least 12 install-release lines, saw ${checked}`);
});

test("the script's header documents both env vars, the exit codes and the bash 3.2 rule", () => {
  const header = scriptText.split("\nset -euo pipefail")[0];
  for (const needle of ["HOV_SETUP_BIN_DIR", "HOV_SETUP_PLATFORM", "HOV_SETUP_RELEASE_TABLE", "consumer", "gate", "defect", "delete-when", "3.2"]) {
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
    writeFileSync(join(w.bin, "install"), `#!/bin/sh\nfor a in "$@"; do case "$a" in *.uvx.hov-setup.*) exit 1 ;; esac; done\nexec /usr/bin/install "$@"\n`);
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
