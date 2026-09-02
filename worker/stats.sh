#!/usr/bin/env bash
#
# Cataclysm usage report, read from the Workers Analytics Engine SQL API.
#
#   worker/stats.sh             query the API and print the report
#   worker/stats.sh --dry-run   print the SQL instead, no credentials needed
#
# The credential is an API token carrying "Account | Account Analytics | Read",
# which is a different one from the wrangler login session used for deploys.
# It is read from CLOUDFLARE_API_TOKEN or, failing that, the login keychain,
# and is never written to a file, a log or the report.
#
# Analytics Engine cannot JOIN, so cohort retention is two queries joined here
# in jq. Day and week buckets are epoch arithmetic rather than a date function
# so the SQL leans on as little of the dialect as possible; weeks therefore
# start on a Thursday (epoch day 0) and the cohort week is computed from the
# install-created date on the same grid.

set -euo pipefail

# Command substitution replaces stdout, so --dry-run writes the SQL to a copy
# of the original stdout instead. `stats.sh --dry-run | grep SELECT` still works.
exec 3>&1

readonly DOWNLOADS_TABLE="cataclysm_downloads"
readonly PINGS_TABLE="cataclysm_pings"

# The reserved probe identity the live checks send. It is a real install id to
# the Worker and must never reach a number anyone reads.
readonly PROBE_INSTALL="00000000-0000-0000-0000-000000000000"

readonly WINDOW_DAYS=90
readonly JAIL_WINDOW_DAYS=7
readonly DAY=86400
readonly WEEK=604800

# Every pings query carries both: the retention window and the probe exclusion.
readonly PINGS_WHERE="timestamp > NOW() - INTERVAL '${WINDOW_DAYS}' DAY AND index1 != '${PROBE_INSTALL}'"
readonly DOWNLOADS_WHERE="timestamp > NOW() - INTERVAL '${WINDOW_DAYS}' DAY"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *)
    echo "usage: ${0##*/} [--dry-run]" >&2
    exit 64
    ;;
esac
readonly DRY_RUN

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
account_id="$(awk -F'"' '/^account_id/ { print $2; exit }' "$script_dir/wrangler.toml")"
if [[ -z "$account_id" ]]; then
  echo "stats.sh: no account_id in $script_dir/wrangler.toml" >&2
  exit 1
fi
# STATS_API_URL is the test seam: the suite points it at a local server that
# answers with fixture rows.
readonly API_URL="${STATS_API_URL:-https://api.cloudflare.com/client/v4/accounts/${account_id}/analytics_engine/sql}"

command -v jq >/dev/null || { echo "stats.sh: jq is required" >&2; exit 1; }

token=""
if (( DRY_RUN == 0 )); then
  command -v curl >/dev/null || { echo "stats.sh: curl is required" >&2; exit 1; }
  token="${CLOUDFLARE_API_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token="$(security find-generic-password -s claude-local-cloudflare -w 2>/dev/null || true)"
  fi
  if [[ -z "$token" ]]; then
    echo "stats.sh: no analytics token. Set CLOUDFLARE_API_TOKEN, or store one" >&2
    echo "          with: security add-generic-password -s claude-local-cloudflare -a \"\$USER\" -U -w \"\$(pbpaste)\"" >&2
    exit 1
  fi
fi
readonly token

# A dataset that has never been written does not exist yet, and the API says so
# rather than returning nothing. That is an empty table, not a failure. The
# message must name one of our datasets: a bare "does not exist" is just as
# likely a mistyped column, and that has to fail loudly.
is_missing_table() {
  grep -qiE "unknown table|table .* not found|does not exist|doesn'?t exist" <<<"$1" \
    && grep -qE "${DOWNLOADS_TABLE}|${PINGS_TABLE}" <<<"$1"
}

# Runs one SQL statement and prints its rows as a compact JSON array.
run_query() {
  local sql="$1"
  if (( DRY_RUN )); then
    printf '%s;\n\n' "$sql" >&3
    echo '[]'
    return
  fi

  # The token rides in on stdin (`-H @-`) so it never appears in curl's
  # argument list, which any local process can read.
  local response status body data
  response="$(curl -sS -X POST "$API_URL" \
    -H @- \
    --data-binary "$sql" \
    -w $'\n%{http_code}' <<<"Authorization: Bearer ${token}")" || {
    echo "stats.sh: request to the SQL API failed" >&2
    exit 1
  }
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "$status" != 2* ]] || ! data="$(jq -ce '.data' <<<"$body" 2>/dev/null)"; then
    if is_missing_table "$body"; then
      echo '[]'
      return
    fi
    printf 'stats.sh: SQL API returned %s\n%s\n' "$status" "$body" >&2
    printf 'query: %s\n' "$sql" >&2
    exit 1
  fi
  echo "$data"
}

# Sampling would make every count below an estimate, so the report refuses to
# print rather than quietly reporting a scaled number.
assert_no_sampling() {
  local table="$1" where="$2" data max
  data="$(run_query "SELECT max(_sample_interval) AS max_interval FROM ${table} WHERE ${where}")"
  max="$(jq -r 'if length == 0 then 1 else (.[0].max_interval // 1) end | tonumber | floor' <<<"$data")"
  if (( max > 1 )); then
    echo "stats.sh: ${table} is sampled (max _sample_interval = ${max})." >&2
    echo "          Counts would be estimates; refusing to print." >&2
    exit 2
  fi
}

section() {
  printf '\n%s\n' "$1"
}

assert_no_sampling "$DOWNLOADS_TABLE" "$DOWNLOADS_WHERE"
assert_no_sampling "$PINGS_TABLE" "$PINGS_WHERE"

section "Downloads per day (last ${WINDOW_DAYS} days)"
run_query "SELECT intDiv(toUnixTimestamp(timestamp), ${DAY}) AS day, sum(_sample_interval) AS downloads FROM ${DOWNLOADS_TABLE} WHERE ${DOWNLOADS_WHERE} GROUP BY day ORDER BY day ASC" \
  | jq -r --argjson day "$DAY" '
      if length == 0 then "  (none)"
      else .[] | "  \((.day | tonumber) * $day | todate[0:10])  \(.downloads)"
      end'

section "Daily active installs (last ${WINDOW_DAYS} days)"
run_query "SELECT intDiv(toUnixTimestamp(timestamp), ${DAY}) AS day, count(DISTINCT index1) AS installs FROM ${PINGS_TABLE} WHERE ${PINGS_WHERE} GROUP BY day ORDER BY day ASC" \
  | jq -r --argjson day "$DAY" '
      if length == 0 then "  (none)"
      else .[] | "  \((.day | tonumber) * $day | todate[0:10])  \(.installs)"
      end'

section "Weekly active installs (last ${WINDOW_DAYS} days, weeks start Thursday)"
run_query "SELECT intDiv(toUnixTimestamp(timestamp), ${WEEK}) AS week, count(DISTINCT index1) AS installs FROM ${PINGS_TABLE} WHERE ${PINGS_WHERE} GROUP BY week ORDER BY week ASC" \
  | jq -r --argjson week "$WEEK" '
      if length == 0 then "  (none)"
      else .[] | "  \((.week | tonumber) * $week | todate[0:10])  \(.installs)"
      end'

section "Cursor lock share (last ${JAIL_WINDOW_DAYS} days, weighted by heartbeat)"
run_query "SELECT double2 AS jail, sum(_sample_interval) AS pings FROM ${PINGS_TABLE} WHERE timestamp > NOW() - INTERVAL '${JAIL_WINDOW_DAYS}' DAY AND index1 != '${PROBE_INSTALL}' GROUP BY jail" \
  | jq -r '
      (map(.pings | tonumber) | add // 0) as $total
      | (map(select((.jail | tonumber) > 0) | (.pings | tonumber)) | add // 0) as $jail
      | if $total == 0 then "  (no heartbeats)"
        else "  \($jail) of \($total) heartbeats with the cursor lock on (\(($jail * 100 / $total) | round)%)"
        end'

# Retention needs both halves of the join, so both queries run even when the
# first comes back empty; that also keeps --dry-run printing every statement.
cohorts="$(run_query "SELECT index1 AS install, min(blob2) AS created FROM ${PINGS_TABLE} WHERE ${PINGS_WHERE} GROUP BY install")"
actives="$(run_query "SELECT index1 AS install, intDiv(toUnixTimestamp(timestamp), ${WEEK}) AS week FROM ${PINGS_TABLE} WHERE ${PINGS_WHERE} GROUP BY install, week")"

section "Weekly cohort retention (cohort = install date, share still active)"
jq -rn --argjson cohorts "$cohorts" --argjson actives "$actives" --argjson week "$WEEK" '
  def pad(n): tostring | if length >= n then . else (" " * (n - length)) + . end;
  def week_of_date: (. + "T00:00:00Z" | fromdateiso8601) / $week | floor;
  def week_label: (. * $week) | todate[0:10];

  ($cohorts
    | map(select(.created != null and (.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))))
    | map({ install: .install, cw: (.created | week_of_date) })) as $installs
  | if ($installs | length) == 0 then "  (no installs yet)"
    else
      ($installs | INDEX(.install) | map_values(.cw)) as $cohort_of
      | ($actives
          | map(select($cohort_of[.install] != null))
          | map({ cw: $cohort_of[.install], off: ((.week | tonumber) - $cohort_of[.install]) })
          # A heartbeat before the install date means a skewed clock, not a cohort.
          | map(select(.off >= 0))) as $cells
      | (reduce $cells[] as $c ({}; .["\($c.cw)|\($c.off)"] += 1)) as $counts
      | (($cells | map(.off) | max) // 0) as $last
      | ($installs | group_by(.cw) | map({ cw: .[0].cw, size: length }) | sort_by(.cw)) as $rows
      | ("  cohort      size" + ([range(0; $last + 1) | ("w\(.)" | pad(6))] | join("")))
      , ($rows[]
          | . as $r
          | "  \($r.cw | week_label) " + ($r.size | pad(5))
            + ([range(0; $last + 1)
                 | ($counts["\($r.cw)|\(.)"] // 0) as $n
                 | (if $n == 0 then "-" else "\(($n * 100 / $r.size) | round)%" end)
                 | pad(6)]
               | join("")))
    end'

printf '\n'
