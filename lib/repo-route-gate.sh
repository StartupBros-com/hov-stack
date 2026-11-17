# shellcheck shell=bash
# lib/repo-route-gate.sh: whether an unattended run may change a checkout (fetch into it,
# fast-forward it, switch its branch), by the repository routes registered on this host
# (scripts/repo-route.py). One copy, so the callers refuse the same checkouts for the same
# reasons: scripts/launchpad-freshen.sh applies it to every launch pad, and ./setup --sync to its
# own checkout before the fetch, which the SessionStart hook starts without freshen.
#
# repo_route_gate <repo> <resolver>: 0 when the route allows the change; 1 when it refuses, with
# the reason in route_gate_why. A resolver that fails or prints anything but a JSON object
# refuses, as do an unverified, ambiguous or misconfigured route, an absent canonical launch
# pad, and, once a route is in warn or enforce mode, a checkout that is not its registered
# canonical one or a route with no authority registered on this host.
# shellcheck disable=SC2034  # route_gate_why is the callers' to read
route_gate_why=
repo_route_gate() {
  local repo=$1 resolver=$2 result fields state mode route canonical missing
  route_gate_why=
  result=$(python3 "$resolver" resolve --repo "$repo" --format json 2>/dev/null) || {
    route_gate_why="repo-route resolver failed; skipped before mutation"
    return 1
  }
  # One parse for the five fields, joined by the unit separator (a newline or separator inside a
  # value becomes a space), each with the default an absent key has always had here.
  fields=$(printf '%s' "$result" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = (d.get("classification", "unverified"), d.get("mode", "observe"), d.get("route", ""),
     d.get("canonical_path", "(unknown canonical)"), d.get("canonical_missing", False))
print("\x1f".join(str(x).replace("\n", " ").replace("\x1f", " ") for x in v))
' 2>/dev/null) || {
    route_gate_why="repo-route resolver returned invalid JSON; skipped before mutation"
    return 1
  }
  IFS=$'\x1f' read -r state mode route canonical missing <<< "$fields" || :
  if [ "$missing" = True ]; then
    route_gate_why="canonical launchpad is absent; only a linked sibling may be resumed/adopted, skipped before mutation"
    return 1
  fi
  case "$state" in
    unverified|ambiguous|misconfigured|error)
      route_gate_why="repo route $state; skipped before mutation"
      return 1 ;;
    unregistered)
      if [ -n "$route" ] && { [ "$mode" = warn ] || [ "$mode" = enforce ]; }; then
        route_gate_why="enrolled route $route has no authority registered on this host; skipped mutation"
        return 1
      fi ;;
    noncanonical-independent-clone|canonical-sibling)
      if [ "$mode" = warn ] || [ "$mode" = enforce ]; then
        route_gate_why="$state for enrolled route; skipped mutation (canonical: $canonical)"
        return 1
      fi ;;
  esac
  return 0
}
