#!/usr/bin/env bash
# audit-summary.sh [path ...]      (default ./audit.jsonl; "-" reads stdin; *.gz is read through gzip)
#
# Weekly review of the container's audit log (design 4.8, 5 item 4). Copy the file to the
# Mac first, from hildanet, e.g.
#   pct pull <CTID> /var/log/notetaker-remote/audit.jsonl ./audit.jsonl
# (and the rotated audit.jsonl.*.gz if you want a longer window), then run this.
#
# Prints: time span; counts per event and per tool; distinct client IPs; p95 latency
# (ms, nearest rank) and error count per tool; response bytes per day; notices about
# the log itself (suppressed-line summaries, the size-ceiling marker, unparseable
# X-Forwarded-For); every anomaly line verbatim (re-serialised as ASCII JSON); and a
# final "ANOMALIES: n". Exit code 0 whenever the file could be read: the count is for
# you, not for a pager. 64 usage, 66 unreadable input.
#
# Anomalies (design 4.8 "login.denied or refresh.reuse" cue, plus the rest of the
# forensic set): login.denied, refresh.reuse, code.reuse, replica.contaminated,
# auth.tarpit, and audit.truncated (the size ceiling was hit: detail lines were dropped).
#
# The audit log never holds note bodies, snippets, titles-of-results or token values, so
# nothing sensitive is printed. Lines that are not valid JSON (a half-written last line
# of a live copy) are skipped and counted.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-checks.sh
. "$DIR/lib-checks.sh"

usage() {
  echo "usage: $(basename "$0") [path ...]   (default ./audit.jsonl; '-' = stdin; .gz accepted)" >&2
  exit 64
}
for a in "$@"; do
  [[ "$a" == "-" || "$a" != -* ]] || usage
done
need_tools jq column gzip
make_work

[[ $# -gt 0 ]] || set -- ./audit.jsonl
: > "$WORK/raw"
for f in "$@"; do
  if [[ "$f" == "-" ]]; then
    cat >> "$WORK/raw"
  elif [[ -r "$f" && -f "$f" ]]; then
    case "$f" in
      *.gz) gzip -dc -- "$f" >> "$WORK/raw" ;;
      *) cat -- "$f" >> "$WORK/raw" ;;
    esac
    # A copy cut mid-write may lack a final newline.
    printf '\n' >> "$WORK/raw"
  else
    echo "audit-summary: cannot read '$(printable "$f")'" >&2
    exit 66
  fi
done

jq -R -c 'fromjson? | select(type == "object")' "$WORK/raw" > "$WORK/lines" 2> /dev/null || true
total=$(grep -c . "$WORK/raw" || true)
valid=$(grep -c . "$WORK/lines" || true)
bad=$((total - valid))

# Lines that did not parse but still name an anomaly event must not vanish silently.
jq -R -r 'select(((try fromjson catch null) | type) != "object")' "$WORK/raw" 2> /dev/null |
  { grep -E 'login\.denied|refresh\.reuse|code\.reuse|replica\.contaminated|auth\.tarpit|audit\.truncated' || true; } |
  cut -c1-300 > "$WORK/bad-anomalies"
bad_anomalies=$(grep -c . "$WORK/bad-anomalies" || true)

ANOMALY_EVENTS='["login.denied","refresh.reuse","code.reuse","replica.contaminated","auth.tarpit","audit.truncated"]'
anomalies=$(jq -s --argjson a "$ANOMALY_EVENTS" '[.[] | select(.event as $e | $a | index($e))] | length' "$WORK/lines")
anomalies=$((anomalies + bad_anomalies))

{
  echo "== audit summary"
  echo "lines: $valid valid JSON, $bad skipped (not JSON; a half-written last line is normal)"
  jq -rs 'if length == 0 then "span: (empty)" else "span: " + ((map(.ts // empty) | min) // "?") + " .. " + ((map(.ts // empty) | max) // "?") end' "$WORK/lines"

  echo
  echo "== events"
  jq -rs 'group_by(.event // "(none)") | map({e: (.[0].event // "(none)"), n: length}) | sort_by(-.n, .e) | if length == 0 then "(none)" else .[] | "\(.n)\t\(.e)" end' "$WORK/lines" | column -t -s "$(printf '\t')" || true

  echo
  echo "== tools (tool.call + tool.error): calls, errors, p95 ms"
  jq -rs '
    [.[] | select((.event == "tool.call" or .event == "tool.error") and .tool != null)]
    | group_by(.tool)
    | map({t: .[0].tool, n: length, err: (map(select(.event == "tool.error")) | length),
           ms: (map(.ms // empty) | sort)})
    | sort_by(-.n, .t)
    | if length == 0 then "(no tool calls)" else .[] |
        "\(.t)\t\(.n) calls\t\(.err) errors\tp95 \(if (.ms | length) == 0 then "?" else (.ms[(((.ms | length) * 0.95) | ceil) - 1]) end) ms"
      end' "$WORK/lines" | column -t -s "$(printf '\t')" || true

  echo
  echo "== client IPs (distinct values of ip)"
  jq -rs '
    [.[] | select(.ip != null and .ip != "") | .ip] | group_by(.) | map({ip: .[0], n: length}) | sort_by(-.n, .ip)
    | if length == 0 then "(none recorded: NR_TRUST_FORWARDED_FOR=0 means no client IP is read; expected until stage 2 decides)"
      else "\(length) distinct", (.[] | "\(.n)\t\(.ip)") end' "$WORK/lines" | column -t -s "$(printf '\t')" || true

  echo
  echo "== response bytes per day (tool.call + tool.error)"
  jq -rs '
    [.[] | select(.bytes != null and (.ts // "") != "") | {d: .ts[0:10], b: .bytes}]
    | group_by(.d) | map({d: .[0].d, b: (map(.b) | add)})
    | if length == 0 then "(none)" else .[] | "\(.d)\t\(.b) bytes" end' "$WORK/lines" | column -t -s "$(printf '\t')" || true

  echo
  echo "== notices about the log itself"
  jq -rs '
    ([.[] | select(.event == "audit.suppressed")]) as $s
    | ([.[] | select(.event == "audit.truncated")]) as $t
    | ([.[] | select(.event == "xff.unparseable") | .result_count // 0] | add // 0) as $x
    | (if ($s | length) == 0 then "suppressed: none"
       else "suppressed: \($s | map(.result_count // 0) | add) line(s) dropped by the per-minute cap, so event counts above are LOWER BOUNDS for: "
            + ($s | group_by(.reason // "?") | map("\(.[0].reason // "?") x\(map(.result_count // 0) | add)") | join(", ")) end),
      (if ($t | length) == 0 then "truncated: no size-ceiling marker"
       else "truncated: \($t | length) audit.truncated marker(s) (first at \($t[0].ts // "?")) - after the ceiling only forensic events were kept; check logrotate (maxsize 64M, hourly timer)" end),
      (if $x == 0 then "xff.unparseable: none" else "xff.unparseable: \($x) request(s) had an X-Forwarded-For whose last hop was not an address" end),
      ("server.start: \([.[] | select(.event == "server.start")] | length) (restarts in this window)"),
      ("kill: \([.[] | select(.event == "kill")] | length)"),
      ("replica.inconsistent / replica.disabled: \([.[] | select(.event == "replica.inconsistent")] | length) / \([.[] | select(.event == "replica.disabled")] | length)"),
      ("auth.ratelimited / rate.limited: \([.[] | select(.event == "auth.ratelimited")] | length) / \([.[] | select(.event == "rate.limited")] | length)")
  ' "$WORK/lines"

  echo
  echo "== anomaly lines (verbatim)"
  if [[ "$anomalies" -eq 0 ]]; then
    echo "(none)"
  else
    jq -a -c --argjson a "$ANOMALY_EVENTS" 'select(.event as $e | $a | index($e))' "$WORK/lines"
  fi

  if [[ "$bad_anomalies" -gt 0 ]]; then
    echo "-- $bad_anomalies line(s) that are NOT valid JSON but mention an anomaly event (first 300 chars):"
    cat "$WORK/bad-anomalies"
  fi

  echo
  echo "ANOMALIES: $anomalies"
} | LC_ALL=C tr -d '\000-\010\013-\037\177'
