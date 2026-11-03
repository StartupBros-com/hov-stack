// Integration: design-rails render against real headless Chrome.
//
// Without Chrome these tests skip and say so. Under CI=true a missing Chrome
// is a failure, so the integration half can never skip silently in CI.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { findChrome } from "../src/render.mjs";
import { withTempDirectory, write } from "./helpers/fixtures.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const cli = join(here, "..", "src", "render.mjs");
const planted = join(here, "fixtures", "render", "planted.html");
const chrome = findChrome();
const inCi = process.env.CI === "true";
const skip = chrome ? false : "no Chrome found (set CHROME_PATH); rendered checks not exercised";

if (!chrome && inCi) {
  test("CI has a Chrome for the rendered checks", () => {
    assert.fail("CI=true but no Chrome was found: install one or set CHROME_PATH");
  });
}

function render(target, extra = []) {
  const r = spawnSync(process.execPath, [cli, target, "--json", "--viewport=1024x768", ...extra], {
    encoding: "utf8",
    timeout: 120000,
  });
  assert.equal(r.status, 0, `render exited ${r.status} (${r.signal || "no signal"}): ${r.stderr}`);
  return { report: JSON.parse(r.stdout), stdout: r.stdout };
}

const idOf = (selector) => (/#([\w-]+)(?![\s\S]*#)/.exec(selector) || [])[1];

test("every planted defect is reported under its rule, and no control is", { skip }, () => {
  const { report } = render(planted);
  assert.equal(report.viewports.length, 1);
  const page = report.viewports[0];
  const got = page.findings.map((f) => `${f.rule} ${f.rule === "page-overflow-x" ? "html" : idOf(f.selector)}`).sort();
  assert.deepEqual(got, [
    "page-overflow-x html",
    "target-size tiny-a",
    "target-size tiny-b",
    "text-clipped clip-y",
    "text-contrast alpha-text",
    "text-contrast faded",
  ]);

  const byRule = (rule) => page.findings.filter((f) => f.rule === rule);
  // The alpha text is measured as the grey it paints, not the black its source names.
  const alpha = byRule("text-contrast").find((f) => idOf(f.selector) === "alpha-text");
  assert.ok(alpha.ratio > 3 && alpha.ratio < 4.5, `alpha-text ratio ${alpha.ratio}`);
  assert.equal(byRule("text-clipped")[0].axis, "y");
  assert.ok(byRule("page-overflow-x")[0].offenders.some((o) => o.selector.includes("#too-wide")));

  // Controls surface where they belong: as advisories, never as findings.
  const a = page.advisories;
  assert.deepEqual(a.truncated.map((t) => [idOf(t.selector), t.by]), [["ellipsis", "ellipsis"]]);
  assert.equal(a.targetsSpacedUnder24, 1, "the lone 20px icon is spaced clear");
  assert.ok(a.contrastUnmeasured >= 1, "text over the gradient is counted as not measured");
  assert.equal(report.total, 6);
});

test("--fail-on gates on the total and every viewport is reported", { skip }, () => {
  const r = spawnSync(process.execPath, [cli, planted, "--json", "--viewport=1024x768,390x844", "--fail-on=0"], {
    encoding: "utf8",
    timeout: 120000,
  });
  assert.equal(r.status, 1, r.stderr);
  const report = JSON.parse(r.stdout);
  assert.deepEqual(report.viewports.map((v) => `${v.width}x${v.height}`), ["1024x768", "390x844"]);
  assert.match(r.stderr, /over the --fail-on budget of 0/);
});

// A page that patches the built-ins a collector would lean on, raises a
// blocking dialog, and names its elements with code-injection strings. The
// collector runs in an isolated world and its results are only JSON-parsed,
// so the hostile page must measure exactly like its clean twin.
test("a hostile page cannot change the result or reach the Node side", { skip }, () => {
  withTempDirectory("design-rails-render-hostile-", (root) => {
    const marker = join(root, "pwned");
    const inject = `\u202e");require("fs").writeFileSync(${JSON.stringify(marker)},"1");("`;
    const body = readFileSync(planted, "utf8")
      .replace("</section>", `<p id='${inject.replaceAll("'", "&#39;")}' style="color:#aaaaaa">\u202ereversed\u202c \u0007bell \${require("fs").writeFileSync(${JSON.stringify(marker).replaceAll('"', "&quot;")},"1")}</p>\n</section>`);
    const hostileScript = `<script>
      Array.prototype.push = function () { return 0; };
      Array.prototype.map = function () { return []; };
      JSON.stringify = function () { return '{"findings":[]}'; };
      JSON.parse = function () { return {}; };
      window.getComputedStyle = function () { return { color: "rgb(255, 255, 255)", backgroundColor: "rgb(255, 255, 255)", opacity: "1" }; };
      Element.prototype.getBoundingClientRect = function () { return new DOMRect(0, 0, 100, 100); };
      Range.prototype.getClientRects = function () { return []; };
      document.createElement = function () { throw new Error("no elements for you"); };
      alert("blocking dialog");
    </script>`;
    write(root, "clean.html", body);
    write(root, "hostile.html", body.replace("</head>", `${hostileScript}\n</head>`));

    const clean = render(join(root, "clean.html"));
    const hostile = render(join(root, "hostile.html"));
    const findings = (r) => r.report.viewports[0].findings;
    assert.ok(findings(clean).length > 6, "the injection-named element is itself a contrast finding");
    assert.deepEqual(findings(hostile), findings(clean));
    assert.deepEqual(hostile.report.viewports[0].advisories, clean.report.viewports[0].advisories);
    assert.equal(existsSync(marker), false, "nothing the page supplied was evaluated");
    assert.doesNotMatch(hostile.stdout, /[\u0000-\u0008\u000b-\u001f\u202a-\u202e]/, "control and bidi characters are stripped");
    const injected = findings(hostile).find((f) => f.selector.includes("writeFileSync"));
    assert.ok(injected, "the injection-named element is reported, as inert text");
  });
});

test("a missing page, a refused scheme and a bad viewport exit 2 before Chrome starts", () => {
  for (const args of [["./no-such-page.html"], ["javascript:alert(1)"], [planted, "--viewport=huge"]]) {
    const r = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", timeout: 30000 });
    assert.equal(r.status, 2, `${args.join(" ")}: ${r.stderr}`);
  }
});
