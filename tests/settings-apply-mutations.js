"use strict";
// Hand tool, not a CI suite: run `node tests/settings-apply-mutations.js` after
// changing lib/settings-apply.js, the SessionStart hook or apply_settings, to
// show each rule's test still fails when that rule is broken. Every case must
// print RED. Each mutation runs against a disposable source tree, never the
// working copy.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {spawnSync} = require("node:child_process");
const root = path.resolve(__dirname,"..");
const cases = [
  ["T1 plan writes base/stamp","lib/settings-apply.js","if (!plan) {","if (true) {","T1"],
  ["T2 empty backup","lib/settings-apply.js",'path.join(candidateBackup, "settings.json"), bytes','path.join(candidateBackup, "settings.json"), ""',"T2"],
  ["T3 disable dcg mapping","lib/settings-apply.js",'? "<dcg>"','? s',"dcg upgrades",true],
  ["T4 disable digest recheck","lib/settings-apply.js","if (digest(fs.readFileSync(args.live)) !== digest(bytes))","if (false)","T4"],
  ["T5 disable link guard","hooks/SessionStart/settings-apply.js",'fs.realpathSync(path.join(cfg, "hooks")) ===\n      fs.realpathSync(path.resolve(__dirname, ".."))','true',"backstop gates",true],
  ["T6 narrow skip alert","hooks/SessionStart/settings-apply.js",'held deny|skipped','held deny|hook\\(s\\) skipped',"backstop gates",true],
  ["T6 sync-level skips silent","hooks/SessionStart/settings-apply.js",'!status.startsWith("skipped (") &&','',"backstop gates",true],
  ["T6 command-less respell","lib/settings-apply.js",'typeof value.command === "string" && cfg','cfg',"command-less hooks",true],
  ["T6 command-less key collision","lib/settings-apply.js",'JSON.stringify(normalize(h))','""',"command-less hooks",true],
  ["T6 malformed events","lib/settings-apply.js",'Array.isArray(groups) ? groups : []','groups',"malformed and pre-existing",true],
  ["T6 prune old empties","lib/settings-apply.js",'for (const event of touched)','for (const event of Object.keys(result))',"malformed and pre-existing",true,
    ['result[event].filter((g) => !emptied.has(g))','result[event].filter((g) => g.hooks.length)']],
  ["T6 unsafe keys","lib/settings-apply.js",'["__proto__", "constructor", "prototype"].includes(k)','false',"dangerous keys",true],
  ["T6 umask mode","lib/settings-apply.js",'fs.fchmodSync(fd, stat.mode & 0o777 || 0o600);','',"T2"],
  ["T6 role roster hash","lib/settings-apply.js",'path.join(root, "hosts.tsv")','""',"role and live deny",true,
    ['overlayDir ? path.join(overlayDir, "hosts.tsv") : ""','""']],
  ["T6 live deny hash","lib/settings-apply.js",'h.update(JSON.stringify(JSON.parse(fs.readFileSync(path.join(cfg, "settings.json"))).permissions?.deny?.slice().sort() ?? []))','h.update("deny ignored")',"T6 role changes"],
  ["T6 skipped base forgotten","lib/settings-apply.js",'put(next,k,copy(b[k]))','put(next,k,copy(d[k]))',"skipped setting",true],
  ["T6 skip validation","sync.sh",'flags+=(--skip-path "env.CLAUDE_ENV_FILE=target is not a regular file")',':',"T6 invalid mapped"],
  ["T6 check engine failure","sync.sh",'echo "DRIFT: settings.json apply check failed: $(head -1 "$settings_tmp/apply-error")"',':',"T6 corrupt base"],
  ["T6 install early return","sync.sh","echo 'install finished everything else, but settings apply failed (see above)' >&2","echo 'install finished everything else, but settings apply failed (see above)' >&2\n    return 1","install reports"],
  ["T6 seed rev role gate","sync.sh",'git -C "$HERE" rev-parse --verify "$rev^{commit}" >/dev/null 2>&1 ||', 'true ||',"T6 seed bad"],
  ["T6 plugin-dirs hash","lib/settings-apply.js",'["settings.json", "env", "plugin-dirs"]','["settings.json", "env"]',"T6 overlay plugin-dirs"],
  ["T6 plugin-dirs append","sync.sh",'    list="$list:$folder"\n','',"T6 overlay plugin-dirs"],
  ["T6 plugin-dirs repeat","sync.sh",'case ":$list:" in *":$folder:"*) continue ;; esac','',"T6 overlay plugin-dirs"],
  ["T6 plugin-dirs manifest","sync.sh",'[ -f "$folder/.claude-plugin/plugin.json" ] || why=','true || why=',"T6 overlay plugin-dirs"],
  ["T6 plugin-dirs colon","sync.sh","*:*) why='it contains a colon","*::::*) why='it contains a colon","T6 overlay plugin-dirs"],
  ["T6 plugin-dirs check exit","sync.sh","sed 's/^/DRIFT: /'; drift=1; }","sed 's/^/DRIFT: /'; }","T6 overlay plugin-dirs"],
];
let killed=0;
for (const [name,file,from,to,pattern,unit,second] of cases) {
  const tmp=fs.mkdtempSync(path.join(os.tmpdir(),"settings-mutant-"));
  try {
    for (const f of ["sync.sh","settings.json","lib","scripts/lib","hooks","mods","managed-settings.json","tests","claude-env.sh"])
      fs.cpSync(path.join(root,f),path.join(tmp,f),{recursive:true});
    const target=path.join(tmp,file);
    let code=fs.readFileSync(target,"utf8");
    if (!code.includes(from)) throw Error("mutation target missing: "+name);
    code=code.replace(from,to);
    if(second) code=code.replace(...second);
    fs.writeFileSync(target,code);
    const r=spawnSync(process.execPath,unit ? ["--test","--test-name-pattern",pattern,path.join(tmp,"hooks/tests/settings-apply.test.js")] : [path.join(tmp,"tests/settings-apply-integration.js")],
      {env:{...process.env,SETTINGS_APPLY_TREE:tmp,SETTINGS_APPLY_CASE:pattern},encoding:"utf8",timeout:120000});
    const red=r.status!==0 && r.status!==null;
    console.log((red?"RED ":"SURVIVED ")+name+" (exit "+r.status+")");
    if(red) killed++; else console.log(r.stdout+r.stderr);
  } finally {fs.rmSync(tmp,{recursive:true,force:true});}
}
console.log(killed+"/"+cases.length+" mutants detected");
process.exitCode=killed===cases.length?0:1;
