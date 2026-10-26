#!/usr/bin/env bash
# Hermetic contract coverage for repo-route.py. Remotes are identity strings;
# no network command is used.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" REPO_ROUTE_HOST_ID=test-host
mkdir -p "$HOME" "$TMP/sites"
export REPO_ROUTE_CONFIG="$TMP/routes.json" REPO_ROUTE_STATE="$TMP/state.json"
cat >"$REPO_ROUTE_CONFIG" <<'EOF'
{
  "version": 1,
  "routes": [
    {
      "id": "acme-app",
      "identities": ["github.com/acme-org/announce-bot"],
      "aliases": ["github.com/old/acme-app"],
      "coordination": {"origin": "same-repo", "fork": {"enabled": false}},
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "missing",
      "identities": ["github.com/o/missing"],
      "directWorktreeDefaultMode": "warn"
    },
    {
      "id": "global-enforce",
      "identities": ["github.com/o/global"],
      "directWorktreeDefaultMode": "enforce"
    },
    {
      "id": "orphan",
      "identities": ["github.com/o/orphan"],
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "vacant",
      "identities": ["github.com/o/vacant"],
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "drift",
      "identities": ["github.com/o/drift"],
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "fork",
      "identities": ["github.com/contributor/acme-app"],
      "coordination": {"origin": "fork", "fork": {"enabled": true, "upstreamMayCoordinate": false, "pushRemote": "origin"}},
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "race-a",
      "identities": ["github.com/o/race-a"],
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "race-b",
      "identities": ["github.com/o/race-b"],
      "directWorktreeDefaultMode": "observe"
    },
    {
      "id": "race-c",
      "identities": ["github.com/o/race-c"],
      "directWorktreeDefaultMode": "observe"
    }
  ]
}
EOF
cp "$REPO_ROUTE_CONFIG" "$TMP/routes.good.json"
R="$HERE/scripts/repo-route.py"
fail(){ echo "FAIL: $*" >&2; exit 1; }
field(){ python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
init_repo(){
  local repo=$1 origin=$2
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.test
  git -C "$repo" config user.name test
  git -C "$repo" commit --allow-empty -qm init
  git -C "$repo" remote add origin "$origin"
}

CANONICAL="$TMP/sites/acme-app"
init_repo "$CANONICAL" git@GitHub.COM:Acme-Org/Announce-Bot.git
python3 "$R" bootstrap --route acme-app --canonical-path "$CANONICAL" --mode enforce >/dev/null
[ "$(stat -c %a "$REPO_ROUTE_STATE")" = 600 ] || fail 'state mode is not 0600'
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = canonical ] || fail 'mixed-case SSH did not resolve canonical'
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['canonical_identity']")" = github.com/acme-org/announce-bot ] || fail 'canonical coordination identity missing'

SIBLING="$TMP/sites/sibling"
git -C "$CANONICAL" worktree add -q -b sibling "$SIBLING"
[ "$(python3 "$R" resolve --repo "$SIBLING" --format json | field "['classification']")" = canonical-sibling ] || fail 'linked worktree became independent clone'
if python3 "$R" bootstrap --route acme-app --canonical-path "$SIBLING" --mode enforce >"$TMP/linked-bootstrap.out"; then
  fail 'linked worktree was accepted as canonical launchpad'
fi
grep -q 'primary launchpad, not a linked worktree' "$TMP/linked-bootstrap.out" || fail 'linked bootstrap rejection was not explicit'
mkdir -p "$CANONICAL/subdir"
if python3 "$R" bootstrap --route acme-app --canonical-path "$CANONICAL/subdir" --mode enforce >"$TMP/subdir-bootstrap.out"; then
  fail 'subdirectory was accepted as canonical launchpad'
fi
grep -q 'checkout top level' "$TMP/subdir-bootstrap.out" || fail 'subdirectory bootstrap rejection was not explicit'

# Bootstrap prevents this state, but a malformed/tampered authority record must
# not promote a linked worktree to the primary launchpad.
cp "$REPO_ROUTE_STATE" "$TMP/state.primary.json"
python3 - "$REPO_ROUTE_STATE" "$SIBLING" <<'PY'
import json, sys
path, sibling = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["routes"]["acme-app"]["canonical_path"] = sibling
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
[ "$(python3 "$R" resolve --repo "$SIBLING" --format json | field "['classification']")" = misconfigured ] || fail 'linked worktree in authority state was treated as canonical'
cp "$TMP/state.primary.json" "$REPO_ROUTE_STATE"

INDEPENDENT="$TMP/sites/independent"
init_repo "$INDEPENDENT" https://github.com/Acme-Org/Announce-Bot.git/
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['classification']")" = noncanonical-independent-clone ] || fail 'HTTPS independent clone did not collide'
cp "$REPO_ROUTE_STATE" "$TMP/state.before-rebind.json"
if python3 "$R" bootstrap --route acme-app --canonical-path "$INDEPENDENT" --mode enforce >"$TMP/rebind.out"; then
  fail 'independent clone replaced an existing matching-host authority'
fi
command grep -q 'different matching-host authority' "$TMP/rebind.out" || fail 'authority replacement rejection was not explicit'
cmp -s "$REPO_ROUTE_STATE" "$TMP/state.before-rebind.json" || fail 'rejected authority replacement rewrote state'
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = canonical ] || fail 'rejected authority replacement displaced the canonical checkout'
python3 "$R" bootstrap --route acme-app --canonical-path "$CANONICAL" --mode enforce >/dev/null || fail 'idempotent bootstrap of the same authority failed'
python3 "$R" scan --sites-root "$TMP/sites" --format json | python3 -c '
import json,sys
groups={g["route"]:g for g in json.load(sys.stdin)["routes"]}
assert groups["acme-app"]["collision"] is True
' || fail 'scan did not classify independent clone collision'
git -C "$INDEPENDENT" remote set-url origin https://github.com/OLD/Acme-App.git
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['route']")" = acme-app ] || fail 'policy alias did not resolve'
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['canonical_identity']")" = github.com/acme-org/announce-bot ] || fail 'alias did not retain canonical coordination identity'
if python3 "$R" bootstrap --route acme-app --canonical-path "$INDEPENDENT" --mode enforce >"$TMP/alias-bootstrap.out"; then
  fail 'alias checkout was accepted as canonical authority'
fi
grep -q 'route primary identity' "$TMP/alias-bootstrap.out" || fail 'alias authority rejection was not explicit'
git -C "$INDEPENDENT" remote set-url origin https://github.com./Acme-Org/Announce-Bot.git
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['route']")" = acme-app ] || fail 'DNS trailing-dot host bypassed enrolled route'
git -C "$INDEPENDENT" remote set-url origin https://github.com:443/Acme-Org/Announce-Bot.git
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['route']")" = acme-app ] || fail 'default HTTPS port bypassed enrolled route'
git -C "$INDEPENDENT" remote set-url origin ssh://git@github.com.:22/Acme-Org/Announce-Bot.git
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['route']")" = acme-app ] || fail 'default SSH port or trailing-dot host bypassed enrolled route'
git -C "$INDEPENDENT" remote set-url origin https://github.com/Acme-Org/Announce-Bot.GIT
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['route']")" = acme-app ] || fail 'uppercase .GIT suffix bypassed enrolled route'
for malformed_origin in \
  https://github.com../Acme-Org/Announce-Bot.git \
  https://github.com/Acme-Org//Announce-Bot.git \
  https://github.com:8443/Acme-Org/Announce-Bot.git; do
  git -C "$INDEPENDENT" remote set-url origin "$malformed_origin"
  [ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['classification']")" = unhosted ] || fail "malformed hosted origin was repaired into authority: $malformed_origin"
done

# Local paths and bundles are explicitly unhosted, never fabricated host identities.
for local_origin in "$TMP/archive/repo.bundle" "file://$TMP/archive/repo.git"; do
  git -C "$INDEPENDENT" remote set-url origin "$local_origin"
  [ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['classification']")" = unhosted ] || fail "local origin was treated as hosted: $local_origin"
done

# A local fetch URL must not hide an effective hosted push endpoint and bypass
# enrolled-route coordination.
git -C "$INDEPENDENT" remote set-url origin "file://$TMP/archive/Acme-Org/Announce-Bot.git"
git -C "$INDEPENDENT" remote set-url --push origin https://github.com/Acme-Org/Announce-Bot.git
python3 "$R" resolve --repo "$INDEPENDENT" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["classification"] == "unverified"
assert r["verified"] is False
assert r["identity"] is None
assert r["push_identity"] == "github.com/acme-org/announce-bot"
' || fail 'local fetch URL hid a hosted push identity'
git -C "$INDEPENDENT" config --unset-all remote.origin.pushurl
git -C "$INDEPENDENT" remote set-url origin https://github.com/Acme-Org/Announce-Bot.git

# Routing must authenticate the endpoint push will use, not only the fetch URL.
git -C "$INDEPENDENT" remote set-url --push origin https://github.com/o/wrong-push.git
python3 "$R" resolve --repo "$INDEPENDENT" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["classification"] == "misconfigured"
assert r["verified"] is False
assert r["identity"] == "github.com/acme-org/announce-bot"
assert r["push_identity"] == "github.com/o/wrong-push"
' || fail 'mismatched origin pushurl was accepted as canonical coordination'
git -C "$INDEPENDENT" config --unset-all remote.origin.pushurl
git -C "$INDEPENDENT" remote set-url --push --add origin git@github.com:Acme-Org/Announce-Bot.git
git -C "$INDEPENDENT" remote set-url --push --add origin https://github.com/Acme-Org/Announce-Bot.git
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['classification']")" = misconfigured ] || fail 'multiple effective push URLs were accepted'
git -C "$INDEPENDENT" config --unset-all remote.origin.pushurl

# Remote URLs may carry userinfo, query credentials, or fragments; diagnostics
# expose only normalized hosted identities.
SECRET_USERINFO=route-secret-userinfo
SECRET_QUERY=route-secret-query
git -C "$INDEPENDENT" remote set-url origin "https://user:${SECRET_USERINFO}@github.com/Acme-Org/Announce-Bot.git?token=${SECRET_QUERY}#fragment"
CREDENTIAL_JSON=$(python3 "$R" resolve --repo "$INDEPENDENT" --format json)
if command grep -Eq "${SECRET_USERINFO}|${SECRET_QUERY}" <<<"$CREDENTIAL_JSON"; then
  fail 'resolver serialized credential-bearing remote material'
fi
printf '%s' "$CREDENTIAL_JSON" | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert "origin" not in r
assert r["identity"] == "github.com/acme-org/announce-bot"
assert r["push_identity"] == "github.com/acme-org/announce-bot"
' || fail 'credential-safe route output dropped normalized identities'
git -C "$INDEPENDENT" remote set-url origin https://github.com/Acme-Org/Announce-Bot.git

# A registered checkout remains bound by its persisted topology if origin is
# removed, changed outside policy, or changed to a different registered route.
git -C "$CANONICAL" remote remove origin
python3 "$R" resolve --repo "$CANONICAL" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["route"] == "acme-app"
assert r["classification"] == "misconfigured"
assert r["verified"] is False
' || fail 'origin removal hid a registered authority as unhosted'
git -C "$CANONICAL" remote add origin https://github.com/o/not-enrolled.git
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = misconfigured ] || fail 'unregistered origin hid a registered authority'
git -C "$CANONICAL" remote set-url origin https://github.com/o/global.git
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = misconfigured ] || fail 'different enrolled origin overrode persisted checkout topology'
git -C "$CANONICAL" remote set-url origin git@GitHub.COM:Acme-Org/Announce-Bot.git

# A stable machine-id keeps authority valid across hostname changes.
printf '%s\n' 0123456789abcdef0123456789abcdef >"$TMP/machine-id"
STABLE_STATE="$TMP/stable-state.json"
env -u REPO_ROUTE_HOST_ID REPO_ROUTE_MACHINE_ID_PATH="$TMP/machine-id" HOSTNAME=before \
  REPO_ROUTE_STATE="$STABLE_STATE" python3 "$R" bootstrap --route acme-app --canonical-path "$CANONICAL" --mode warn >/dev/null
env -u REPO_ROUTE_HOST_ID REPO_ROUTE_MACHINE_ID_PATH="$TMP/machine-id" HOSTNAME=after \
  REPO_ROUTE_STATE="$STABLE_STATE" python3 "$R" resolve --repo "$CANONICAL" --format json \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["classification"] == "canonical"' \
  || fail 'hostname change invalidated stable host authority'
grep -q 'machine-id:0123456789abcdef0123456789abcdef' "$STABLE_STATE" || fail 'stable machine id was not persisted'
if env -u REPO_ROUTE_HOST_ID REPO_ROUTE_MACHINE_ID_PATH="$TMP/no-machine-id" \
  REPO_ROUTE_STATE="$TMP/no-host-state.json" python3 "$R" bootstrap --route acme-app --canonical-path "$CANONICAL" --mode warn >"$TMP/no-host.out"; then
  fail 'bootstrap succeeded without a stable host id'
fi
grep -q 'stable machine id unavailable' "$TMP/no-host.out" || fail 'missing machine id rejection was not explicit'

# A disappeared launchpad leaves surviving same-common-dir siblings resumable only.
MISSING_LAUNCH="$TMP/sites/missing-launchpad"
MISSING_GIT="$TMP/missing.git"
git init -q --separate-git-dir "$MISSING_GIT" "$MISSING_LAUNCH"
git -C "$MISSING_LAUNCH" config user.email test@example.test
git -C "$MISSING_LAUNCH" config user.name test
git -C "$MISSING_LAUNCH" commit --allow-empty -qm init
git -C "$MISSING_LAUNCH" remote add origin https://github.com/o/missing.git
MISSING_SIBLING="$TMP/sites/missing-sibling"
git -C "$MISSING_LAUNCH" worktree add -q -b missing-sibling "$MISSING_SIBLING"
python3 "$R" bootstrap --route missing --canonical-path "$MISSING_LAUNCH" --mode warn >/dev/null
mv "$MISSING_LAUNCH" "$TMP/removed-launchpad"
python3 "$R" resolve --repo "$MISSING_SIBLING" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["classification"] == "canonical-sibling"
assert r["canonical_missing"] is True
assert r["creation_allowed"] is False
assert r["adopt_allowed"] is True
' || fail 'surviving sibling did not fail closed after launchpad disappearance'
python3 "$R" scan --sites-root "$TMP/sites" --format json | python3 -c '
import json,sys
groups={g["route"]:g for g in json.load(sys.stdin)["routes"]}
assert groups["missing"]["canonical_missing"] is True
' || fail 'scan did not report a disappeared canonical launchpad'

# A registered authority must remain visible when its launchpad disappears and
# no sibling checkout survives under the scan root.
ORPHAN="$TMP/sites/orphan"
ORPHAN_INDEPENDENT="$TMP/sites/orphan-independent"
init_repo "$ORPHAN" https://github.com/o/orphan.git
init_repo "$ORPHAN_INDEPENDENT" https://github.com/o/orphan.git
python3 "$R" bootstrap --route orphan --canonical-path "$ORPHAN" --mode observe >/dev/null
mv "$ORPHAN" "$TMP/removed-orphan"
python3 "$R" resolve --repo "$ORPHAN_INDEPENDENT" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["classification"] == "noncanonical-independent-clone"
assert r["canonical_missing"] is True
assert r["healing_allowed"] is False
' || fail 'independent clone did not preserve missing canonical authority'
python3 "$R" scan --sites-root "$TMP/sites" --format json | python3 -c '
import json,sys
groups={g["route"]:g for g in json.load(sys.stdin)["routes"]}
assert groups["orphan"]["canonical_missing"] is True
' || fail 'scan lost a registered authority when its canonical checkout disappeared'

# The scan inventories local authority records, not only surviving children.
VACANT="$TMP/sites/vacant"
init_repo "$VACANT" https://github.com/o/vacant.git
python3 "$R" bootstrap --route vacant --canonical-path "$VACANT" --mode observe >/dev/null
mv "$VACANT" "$TMP/removed-vacant"
python3 "$R" scan --sites-root "$TMP/sites" --format json | python3 -c '
import json,sys
groups={g["route"]:g for g in json.load(sys.stdin)["routes"]}
assert groups["vacant"]["canonical_missing"] is True
assert groups["vacant"]["entries"][0]["classification"] == "canonical-missing"
' || fail 'scan did not synthesize a disappeared authority with zero surviving checkouts'

# State inventory must catch authority drift even when the canonical checkout is
# the route's only surviving checkout and therefore no sibling can name the route.
DRIFT="$TMP/sites/drift"
init_repo "$DRIFT" https://github.com/o/drift.git
python3 "$R" bootstrap --route drift --canonical-path "$DRIFT" --mode observe >/dev/null
git -C "$DRIFT" remote set-url origin https://github.com/o/not-drift.git
python3 "$R" scan --sites-root "$TMP/sites" --format json | python3 -c '
import json,sys
d=json.load(sys.stdin)
groups={g["route"]:g for g in d["routes"]}
assert d["verified"] is False
assert groups["drift"]["unverified"] is True
assert groups["drift"]["entries"][0]["classification"] == "misconfigured"
' || fail 'scan dropped a lone canonical checkout whose origin drifted outside policy'

# Portable enforce policy closes direct creation even before host bootstrap.
GLOBAL="$TMP/sites/global"
init_repo "$GLOBAL" https://github.com/o/global.git
python3 "$R" resolve --repo "$GLOBAL" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["classification"] == "unregistered"
assert r["route"] == "global-enforce"
assert r["mode"] == "enforce"
assert r["authority_registered"] is False
' || fail 'global enforce route without host authority did not remain explicit'

# Fork identities remain separate routes unless policy explicitly coordinates them.
FORK="$TMP/sites/fork"
init_repo "$FORK" git@github.com:contributor/acme-app.git
python3 "$R" resolve --repo "$FORK" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["route"] == "fork"
assert r["canonical_identity"] == "github.com/contributor/acme-app"
assert r["coordination"]["origin"] == "fork"
assert r["coordination"]["fork"]["upstreamMayCoordinate"] is False
' || fail 'fork route was implicitly coordinated with upstream'

# Persisted authority stays bound to the canonical hosted identity and origin.
cp "$REPO_ROUTE_STATE" "$TMP/state.identity.json"
python3 - "$REPO_ROUTE_STATE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["routes"]["acme-app"]["canonical_identity"] = "github.com/o/repurposed"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = unverified ] || fail 'repurposed route id reused stale authority'
cp "$REPO_ROUTE_STATE" "$TMP/state.tampered.json"
if python3 "$R" set-mode --route acme-app --mode enforce >/dev/null 2>&1; then
  fail 'set-mode promoted a tampered authority record'
fi
cmp -s "$REPO_ROUTE_STATE" "$TMP/state.tampered.json" || fail 'failed set-mode rewrote tampered authority state'
cp "$TMP/state.identity.json" "$REPO_ROUTE_STATE"
git -C "$CANONICAL" remote set-url origin https://github.com/OLD/Acme-App.git
[ "$(python3 "$R" resolve --repo "$INDEPENDENT" --format json | field "['classification']")" = misconfigured ] || fail 'canonical authority drift to a route alias was not rejected'
git -C "$CANONICAL" remote set-url origin git@GitHub.COM:Acme-Org/Announce-Bot.git

# A copied foreign-host record is not local authority.
REPO_ROUTE_HOST_ID=other python3 "$R" resolve --repo "$CANONICAL" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["classification"] == "unregistered"
assert r["foreign_host_authority"] is True
assert r["authority_registered"] is False
' || fail 'foreign host authority was treated as local'

# Every authority field is validated before the host comparison. Blank host ids
# and relative/non-normalized paths are malformed, never foreign or canonical.
cp "$REPO_ROUTE_STATE" "$TMP/state.validated.json"
for tamper in blank-host relative-canonical nonnormalized-common; do
  cp "$TMP/state.validated.json" "$REPO_ROUTE_STATE"
  python3 - "$REPO_ROUTE_STATE" "$tamper" "$TMP" <<'PY'
import json, sys
path, tamper, root = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
entry = data["routes"]["acme-app"]
if tamper == "blank-host":
    entry["host_id"] = ""
elif tamper == "relative-canonical":
    entry["canonical_path"] = "sites/acme-app"
else:
    entry["common_dir"] = f"{root}/sites/../sites/acme-app/.git"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  cp "$REPO_ROUTE_STATE" "$TMP/state.tampered-$tamper.json"
  [ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = unverified ] || fail "$tamper authority state did not fail closed"
  if python3 "$R" set-mode --route acme-app --mode warn >/dev/null 2>&1; then
    fail "$tamper authority state accepted a mode mutation"
  fi
  cmp -s "$REPO_ROUTE_STATE" "$TMP/state.tampered-$tamper.json" || fail "$tamper failed mutation rewrote state"
done
cp "$TMP/state.validated.json" "$REPO_ROUTE_STATE"
if REPO_ROUTE_HOST_ID=' ' python3 "$R" set-mode --route acme-app --mode warn >"$TMP/blank-runtime-host.out"; then
  fail 'blank runtime host id was accepted'
fi
command grep -q 'nonblank normalized value' "$TMP/blank-runtime-host.out" || fail 'blank runtime host rejection was not explicit'

# A stable sidecar lock covers the complete read/validate/write sequence. The
# pause seam makes the stale-read lost-update race deterministic.
RACE_A="$TMP/sites/race-a"
RACE_B="$TMP/sites/race-b"
RACE_C="$TMP/sites/race-c"
init_repo "$RACE_A" https://github.com/o/race-a.git
init_repo "$RACE_B" https://github.com/o/race-b.git
init_repo "$RACE_C" https://github.com/o/race-c.git
READY="$TMP/race-a.ready"
REPO_ROUTE_TEST_LOCK_READY="$READY" REPO_ROUTE_TEST_LOCK_DELAY=0.4 \
  python3 "$R" bootstrap --route race-a --canonical-path "$RACE_A" --mode observe >"$TMP/race-a.out" &
RACE_PID=$!
for _ in $(seq 1 200); do [ -e "$READY" ] && break; sleep 0.01; done
[ -e "$READY" ] || fail 'concurrent bootstrap did not reach the locked read seam'
python3 "$R" bootstrap --route race-b --canonical-path "$RACE_B" --mode warn >/dev/null || fail 'contending bootstrap failed'
wait "$RACE_PID" || fail 'delayed bootstrap failed'
python3 - "$REPO_ROUTE_STATE" <<'PY' || fail 'concurrent bootstraps lost an authority update'
import json, sys
routes = json.load(open(sys.argv[1], encoding="utf-8"))["routes"]
assert "race-a" in routes and "race-b" in routes and "acme-app" in routes
PY
[ "$(stat -c %a "$REPO_ROUTE_STATE.lock")" = 600 ] || fail 'state lock mode is not 0600'

READY="$TMP/race-c.ready"
REPO_ROUTE_TEST_LOCK_READY="$READY" REPO_ROUTE_TEST_LOCK_DELAY=0.4 \
  python3 "$R" bootstrap --route race-c --canonical-path "$RACE_C" --mode observe >"$TMP/race-c.out" &
RACE_PID=$!
for _ in $(seq 1 200); do [ -e "$READY" ] && break; sleep 0.01; done
[ -e "$READY" ] || fail 'bootstrap/set-mode race did not reach the locked read seam'
python3 "$R" set-mode --route acme-app --mode warn >/dev/null || fail 'contending set-mode failed'
wait "$RACE_PID" || fail 'bootstrap racing set-mode failed'
python3 - "$REPO_ROUTE_STATE" <<'PY' || fail 'bootstrap/set-mode race lost a mutation'
import json, sys
routes = json.load(open(sys.argv[1], encoding="utf-8"))["routes"]
assert routes["acme-app"]["mode"] == "warn"
assert "race-c" in routes
PY
python3 "$R" set-mode --route acme-app --mode enforce >/dev/null

# A scan infrastructure failure remains one visible unverified route instead of
# becoming a clean zero-count result in maintenance reporting.
python3 "$R" scan --sites-root "$TMP/no-such-sites-root" --format json | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["verified"] is False
assert len(r["routes"]) == 1
assert r["routes"][0]["route"] == "<unresolved>"
assert r["routes"][0]["unverified"] is True
' || fail 'unreadable scan root was reported as zero flagged routes'

# Duplicate aliases fail the policy globally instead of choosing by order.
cat >"$REPO_ROUTE_CONFIG" <<'EOF'
{"version":1,"routes":[{"id":"a","identities":["github.com/o/dup"]},{"id":"b","identities":["github.com/o/dup"]}]}
EOF
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = unverified ] || fail 'ambiguous identity policy did not fail closed'
cp "$TMP/routes.good.json" "$REPO_ROUTE_CONFIG"

cp "$REPO_ROUTE_STATE" "$TMP/state.good.json"
printf '{bad' >"$REPO_ROUTE_STATE"
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = unverified ] || fail 'malformed matching-host state became unregistered'
cp "$TMP/state.good.json" "$REPO_ROUTE_STATE"
printf '%s\n' '{"version":1,"routes":[{"id":"broken","identities":[42]}]}' >"$REPO_ROUTE_CONFIG"
[ "$(python3 "$R" resolve --repo "$CANONICAL" --format json | field "['classification']")" = unverified ] || fail 'malformed policy identity became unregistered'
[ "$(python3 "$R" scan --sites-root "$TMP/sites" --format json | field "['verified']")" = False ] || fail 'scan discarded an unresolved resolver failure'
if python3 "$R" bootstrap --route broken --canonical-path "$CANONICAL" --mode warn >/dev/null; then
  fail 'mutating bootstrap returned success for malformed policy'
fi

# Config resolution: REPO_ROUTE_CONFIG, else overlay copy, else tracked placeholder.
OV="$TMP/overlay"
mkdir -p "$OV"
OVREPO="$TMP/sites/ovrepo"
init_repo "$OVREPO" git@github.com:o/overlay-only.git
TRACKED="$TMP/sites/tracked"
init_repo "$TRACKED" git@github.com:acme-org/announce-bot.git
printf '%s\n' '{"version":1,"routes":[{"id":"overlay-route","identities":["github.com/o/overlay-only"]}]}' >"$OV/repo-routes.json"
printf '%s\n' '{"version":1,"routes":[{"id":"env-route","identities":["github.com/o/overlay-only"]}]}' >"$TMP/env-routes.json"
route_of(){ python3 "$R" resolve --repo "$1" --format json | field "['route']"; }
[ "$(env -u REPO_ROUTE_CONFIG HOV_STACK_OVERLAY="$OV" bash -c "$(declare -f route_of field); R='$R'; route_of '$OVREPO'")" = overlay-route ] || fail 'overlay routes file was not used'
mkdir -p "$TMP/emptyov"
[ "$(env -u REPO_ROUTE_CONFIG HOV_STACK_OVERLAY="$TMP/emptyov" bash -c "$(declare -f route_of field); R='$R'; route_of '$TRACKED'")" = github-acme-org-announce-bot ] || fail 'tracked placeholder was not used without an overlay file'
[ "$(REPO_ROUTE_CONFIG="$TMP/env-routes.json" HOV_STACK_OVERLAY="$OV" bash -c "$(declare -f route_of field); R='$R'; route_of '$OVREPO'")" = env-route ] || fail 'REPO_ROUTE_CONFIG did not win over overlay'

echo "ok — repo-route resolver contract"
