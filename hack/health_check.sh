#!/bin/bash
# Health check of the geo-replicated cluster drtest in both locations. Run it after setting up geo
# replication, after a switchover or failover, or any time to see whether the cluster is sound.
#
# Usage: hack/health_check.sh            read-only checks
#        PROBE=1 hack/health_check.sh    also write a row on the writing side (table healthcheck_probe in the
#                                        postgres database) and wait until every instance in both locations has it
# Exits 0 when every check passes, 1 on warnings only, 2 on failures.
# Override names and thresholds through the environment, e.g. C=other NS=demo MAX_GEO_LAG_MB=128.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

# .env (in the repository root) sets the cluster name, namespace, and the two locations. The script can be run from any context.
# export cluster_name='drtest'
# export project_ns='multi-region'
# export protected_location='protected'
# export recovery_location='recovery'

C=${C:-$cluster_name}
NS=${NS:-$project_ns}
PROTECTED=${PROTECTED:-$protected_location}
RECOVERY=${RECOVERY:-$recovery_location}
LOCATIONS=("$PROTECTED" "$RECOVERY")

MAX_LAG_MB=${MAX_LAG_MB:-64}                 # streaming replica replay lag inside a location
MAX_GEO_LAG_MB=${MAX_GEO_LAG_MB:-64}         # how far the replica location trails (WAL ships through the bucket)
MAX_SLOT_MB=${MAX_SLOT_MB:-1024}             # WAL a replication slot holds back
MAX_ARCHIVE_PENDING=${MAX_ARCHIVE_PENDING:-4} # WAL segments waiting to be archived
MAX_BACKUP_AGE_H=${MAX_BACKUP_AGE_H:-26}     # hours since the last successful base backup
MAX_XACT_AGE=${MAX_XACT_AGE:-300}            # seconds a transaction may stay open
CERT_WARN_DAYS=${CERT_WARN_DAYS:-14}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-600}          # seconds to wait for the probe row in the replica location

if [ -t 1 ]; then G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' B=$'\033[1;34m' D=$'\033[2m' N=$'\033[0m'
else G= Y= R= B= D= N=; fi
PASSES=0 WARNS=0 FAILS=0
pass() { PASSES=$((PASSES + 1)); printf "  ${G}PASS${N}  %-34s %s\n" "$1" "${2:-}"; }
warn() { WARNS=$((WARNS + 1));   printf "  ${Y}WARN${N}  %-34s %s\n" "$1" "${2:-}"; }
fail() { FAILS=$((FAILS + 1));   printf "  ${R}FAIL${N}  %-34s %s\n" "$1" "${2:-}"; }
info() { printf "  ${D}info  %-34s %s${N}\n" "$1" "${2:-}"; }
section() { echo; echo "${B}## $1${N}"; }

K() { local ctx=$1; shift; kubectl --context "$ctx" -n "$NS" --request-timeout=15s "$@"; }
# psql as postgres in a pod; each statement runs in its own transaction, fields are tab separated
psql_at() {
  local ctx=$1 pod=$2 args=(); shift 2
  for s in "$@"; do args+=(-c "$s"); done
  K "$ctx" exec "$pod" -c postgres -- psql -XAtq -d postgres -F $'\t' "${args[@]}" 2>/dev/null
}
mb() { echo $(( ${1:-0} / 1048576 )); }
epoch() { date -d "$(sed -E 's/ [A-Z]+$//' <<<"$1")" +%s 2>/dev/null; }
REPLAY_OR_CURRENT="case when pg_is_in_recovery() then pg_last_wal_replay_lsn() else pg_current_wal_lsn() end"

declare -A JSON PRIMARY WRITING
REACHABLE=() WRITERS=()

echo "cluster: $C  namespace: $NS  locations: ${LOCATIONS[*]}  $(date -u '+%F %T UTC')"

### Topology: exactly one location writes, and both agree on which

section "topology"
for loc in "${LOCATIONS[@]}"; do
  if out=$(K "$loc" get clusters.postgresql.cnpg.io "$C" -o json 2>&1); then
    JSON[$loc]=$out
    REACHABLE+=("$loc")
    PRIMARY[$loc]=$(jq -r '.status.currentPrimary // ""' <<<"$out")
    read -r self prim enabled < <(jq -r '[.spec.replica.self // "-", .spec.replica.primary // "-", .spec.replica.enabled // false] | @tsv' <<<"$out")
    # a location writes when its replica.self equals replica.primary (or it isn't a replica cluster at all)
    if [ "$prim" != - ]; then [ "$self" = "$prim" ] && WRITING[$loc]=1 || WRITING[$loc]=0
    else [ "$enabled" = true ] && WRITING[$loc]=0 || WRITING[$loc]=1; fi
    [ "${WRITING[$loc]}" = 1 ] && WRITERS+=("$loc")
    pass "$loc reachable" "self=$self primary=$prim pod=${PRIMARY[$loc]:-none}"
  else
    fail "$loc reachable" "$(head -1 <<<"$out")"
  fi
done

case ${#WRITERS[@]} in
  1) pass "one writing location" "${WRITERS[0]}" ;;
  0) fail "one writing location" "no location writes (promotion pending or stuck?)" ;;
  *) fail "one writing location" "split brain: ${WRITERS[*]} all write" ;;
esac
WRITER=; [ ${#WRITERS[@]} = 1 ] && WRITER=${WRITERS[0]}

if [ ${#REACHABLE[@]} -gt 1 ]; then
  primaries=$(for loc in "${REACHABLE[@]}"; do jq -r '.spec.replica.primary // "-"' <<<"${JSON[$loc]}"; done | sort -u)
  [ "$(wc -l <<<"$primaries")" = 1 ] \
    && pass "locations agree on the primary" "$primaries" \
    || fail "locations agree on the primary" "$(tr '\n' ' ' <<<"$primaries")"
else
  warn "locations agree on the primary" "only ${REACHABLE[*]:-none} reachable"
fi

### Per location: cluster status, pods, roles, streaming replicas, slots, settings, certificates

check_location() {
  local loc=$1 j=${JSON[$1]} pod=${PRIMARY[$1]} role=replica
  [ "${WRITING[$loc]}" = 1 ] && role=writing
  section "$loc ($role)"

  local phase ready inst cur tgt
  read -r ready inst cur tgt < <(jq -r '[.status.readyInstances // 0, .status.instances // 0, .status.currentPrimary // "-", .status.targetPrimary // "-"] | @tsv' <<<"$j")
  phase=$(jq -r '.status.phase // "unknown"' <<<"$j")
  [ "$phase" = "Cluster in healthy state" ] && pass "phase" "$phase" || warn "phase" "$phase"
  if [ "$ready" = "$inst" ] && [ "$inst" -gt 0 ]; then pass "instances ready" "$ready/$inst"
  elif [ "$ready" -gt 0 ]; then warn "instances ready" "$ready/$inst"
  else fail "instances ready" "$ready/$inst"; fi
  [ "$cur" = "$tgt" ] && pass "current = target primary" "$cur" \
    || warn "current = target primary" "$cur -> $tgt (switchover/failover in progress)"

  local cond
  cond=$(jq -r '.status.conditions[]? | select(.type=="Ready") | "\(.status)\t\(.message // "")"' <<<"$j")
  [ "${cond%%$'\t'*}" = True ] && pass "condition Ready" || warn "condition Ready" "${cond:-missing}"
  if [ "$role" = writing ]; then
    cond=$(jq -r '.status.conditions[]? | select(.type=="ContinuousArchiving") | "\(.status)\t\(.message // "")"' <<<"$j")
    [ "${cond%%$'\t'*}" = True ] && pass "condition ContinuousArchiving" || fail "condition ContinuousArchiving" "${cond:-missing}"
  fi
  local fenced
  fenced=$(jq -r '.metadata.annotations["cnpg.io/fencedInstances"] // ""' <<<"$j")
  [ -z "$fenced" ] || [ "$fenced" = "[]" ] && pass "no fenced instances" || warn "no fenced instances" "$fenced"

  # pods: all ready, exactly one labelled primary and it is the current primary
  local pods unready primaries
  pods=$(K "$loc" get pods -l cnpg.io/cluster="$C" -o json 2>/dev/null \
    | jq -r '.items[] | [.metadata.name, (.metadata.labels["cnpg.io/instanceRole"] // .metadata.labels.role // "-"),
        ([.status.containerStatuses[]?.ready] | all), .spec.nodeName // "-"] | @tsv')
  unready=$(awk -F'\t' '$3 != "true" {print $1}' <<<"$pods" | xargs)
  primaries=$(awk -F'\t' '$2 == "primary" {print $1}' <<<"$pods" | xargs)
  [ -z "$unready" ] && pass "pods ready" "$(awk -F'\t' '{printf "%s(%s@%s) ", $1, $2, $4}' <<<"$pods")" \
    || fail "pods ready" "not ready: $unready"
  [ "$primaries" = "$pod" ] && pass "one pod labelled primary" "$primaries" \
    || fail "one pod labelled primary" "labelled: ${primaries:-none}, status says: ${pod:-none}"

  [ -n "$pod" ] || { fail "primary pod" "no current primary"; return; }
  local rec
  rec=$(psql_at "$loc" "$pod" "select pg_is_in_recovery()")
  if [ -z "$rec" ]; then fail "postgres on $pod" "psql failed"; return; fi
  if [ "$role" = writing ]; then
    [ "$rec" = f ] && pass "$pod accepts writes" || fail "$pod accepts writes" "still in recovery"
  else
    [ "$rec" = t ] && pass "$pod in recovery" "designated primary replays from the bucket" \
      || fail "$pod in recovery" "it is a read-write primary in a replica location"
  fi

  # streaming replicas inside the location
  local streaming lag names
  IFS=$'\t' read -r streaming lag names < <(psql_at "$loc" "$pod" "
    select count(*) filter (where state = 'streaming'),
           coalesce(max(pg_wal_lsn_diff($REPLAY_OR_CURRENT, replay_lsn)), 0)::bigint,
           coalesce(string_agg(application_name || ':' || state || '/' || sync_state, ' '), '-')
    from pg_stat_replication")
  if [ "${streaming:-0}" -ge $((inst - 1)) ]; then pass "streaming replicas" "$streaming/$((inst - 1)) $names"
  else fail "streaming replicas" "${streaming:-0}/$((inst - 1)) $names"; fi
  [ "$(mb "$lag")" -le "$MAX_LAG_MB" ] && pass "replica replay lag" "$(mb "$lag") MB" \
    || warn "replica replay lag" "$(mb "$lag") MB > $MAX_LAG_MB MB"

  # replication slots
  local inactive retained inactive_names
  IFS=$'\t' read -r inactive retained inactive_names < <(psql_at "$loc" "$pod" "
    select count(*) filter (where not active),
           coalesce(max(pg_wal_lsn_diff($REPLAY_OR_CURRENT, restart_lsn)), 0)::bigint,
           coalesce(string_agg(slot_name, ' ') filter (where not active), '')
    from pg_replication_slots")
  [ "${inactive:-0}" = 0 ] && pass "replication slots active" || warn "replication slots active" "inactive: $inactive_names"
  [ "$(mb "$retained")" -le "$MAX_SLOT_MB" ] && pass "WAL held by slots" "$(mb "$retained") MB" \
    || warn "WAL held by slots" "$(mb "$retained") MB > $MAX_SLOT_MB MB"

  local pending
  pending=$(psql_at "$loc" "$pod" "select string_agg(name, ' ') from pg_settings where pending_restart")
  [ -z "$pending" ] && pass "no settings waiting for restart" || warn "no settings waiting for restart" "$pending"

  if [ "$role" = writing ]; then
    # WAL archiving: segments waiting (.ready) and a failure newer than the last success
    local ready_files failed last_wal
    IFS=$'\t' read -r ready_files failed last_wal < <(psql_at "$loc" "$pod" "
      select (select count(*) from pg_ls_dir('pg_wal/archive_status') f where f like '%.ready'),
             coalesce(last_failed_time > last_archived_time, last_failed_time is not null),
             coalesce(last_archived_wal, '-')
      from pg_stat_archiver")
    [ "$failed" = f ] && pass "WAL archiving" "last archived $last_wal" || fail "WAL archiving" "last attempt failed (bucket reachable?)"
    [ "${ready_files:-0}" -le "$MAX_ARCHIVE_PENDING" ] && pass "WAL waiting for archive" "${ready_files:-0} segments" \
      || warn "WAL waiting for archive" "$ready_files segments > $MAX_ARCHIVE_PENDING"

    local long oldest blocked
    IFS=$'\t' read -r long oldest blocked < <(psql_at "$loc" "$pod" "
      select count(*) filter (where now() - xact_start > interval '$MAX_XACT_AGE seconds'),
             coalesce(max(extract(epoch from now() - xact_start))::int, 0),
             count(*) filter (where cardinality(pg_blocking_pids(pid)) > 0)
      from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()")
    [ "${long:-0}" = 0 ] && pass "no long transactions" "oldest ${oldest}s" \
      || warn "no long transactions" "$long open > ${MAX_XACT_AGE}s, oldest ${oldest}s"
    [ "${blocked:-0}" = 0 ] && pass "no blocked sessions" || warn "no blocked sessions" "$blocked waiting on a lock"
  fi

  # certificates
  local now soonest= soonest_name name exp days
  now=$(date +%s)
  while IFS=$'\t' read -r name exp; do
    exp=$(epoch "$exp") || continue
    days=$(( (exp - now) / 86400 ))
    if [ -z "$soonest" ] || [ "$days" -lt "$soonest" ]; then soonest=$days soonest_name=$name; fi
  done < <(jq -r '.status.certificates.expirations // {} | to_entries[] | "\(.key)\t\(.value)"' <<<"$j")
  if [ -z "$soonest" ]; then warn "certificates" "no expiry dates in status"
  elif [ "$soonest" -lt 1 ]; then fail "certificates" "$soonest_name expired"
  elif [ "$soonest" -lt "$CERT_WARN_DAYS" ]; then warn "certificates" "$soonest_name expires in $soonest days"
  else pass "certificates" "first to expire: $soonest_name in $soonest days"; fi

  # poolers of this cluster: deployment ready and not paused
  local pname pinst paused pready
  while IFS=$'\t' read -r pname pinst paused; do
    [ -n "$pname" ] || continue
    pready=$(K "$loc" get deploy "$pname" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "$paused" = true ]; then warn "pooler $pname" "paused"
    elif [ "${pready:-0}" -ge "$pinst" ]; then pass "pooler $pname" "${pready:-0}/$pinst ready"
    else fail "pooler $pname" "${pready:-0}/$pinst ready"; fi
  done < <(K "$loc" get poolers.postgresql.cnpg.io -o json 2>/dev/null \
    | jq -r --arg c "$C" '.items[] | select(.spec.cluster.name == $c) | [.metadata.name, .spec.instances // 1, .spec.pgbouncer.paused // false] | @tsv')
}

for loc in "${REACHABLE[@]}"; do check_location "$loc"; done

### Geo replication: how far each replica location trails the writing location

if [ -n "$WRITER" ]; then
  section "geo replication (from $WRITER)"
  wpod=${PRIMARY[$WRITER]}
  wtl=$(psql_at "$WRITER" "$wpod" "select timeline_id from pg_control_checkpoint()")
  for loc in "${REACHABLE[@]}"; do
    [ "$loc" = "$WRITER" ] && continue
    rpod=${PRIMARY[$loc]}
    IFS=$'\t' read -r lsn delay rtl < <(psql_at "$loc" "$rpod" "
      select pg_last_wal_replay_lsn(), coalesce(extract(epoch from now() - pg_last_xact_replay_timestamp())::int, -1),
             (select timeline_id from pg_control_checkpoint())")
    if [ -z "${lsn:-}" ]; then fail "$loc replays WAL" "$rpod reports no replay position"; continue; fi
    behind=$(psql_at "$WRITER" "$wpod" "select greatest(pg_wal_lsn_diff(pg_current_wal_lsn(), '$lsn'), 0)::bigint")
    if [ -z "$behind" ]; then fail "$loc behind $WRITER" "could not compare positions"
    elif [ "$(mb "$behind")" -le "$MAX_GEO_LAG_MB" ]; then pass "$loc behind $WRITER" "$(mb "$behind") MB"
    else warn "$loc behind $WRITER" "$(mb "$behind") MB > $MAX_GEO_LAG_MB MB"; fi
    info "$loc last replayed commit" "$([ "$delay" -ge 0 ] && echo "${delay}s ago" || echo never) (old on an idle cluster)"
    info "timelines" "$WRITER=$wtl $loc=$rtl (the replica catches up at its next restartpoint)"
  done

  ### Backups of the writing location

  section "backups ($WRITER)"
  read -r store server < <(jq -r --arg c "$C" '.spec.plugins[]? | select(.name == "barman-cloud.cloudnative-pg.io")
    | [.parameters.barmanObjectName // "-", .parameters.serverName // $c] | @tsv' <<<"${JSON[$WRITER]}")
  if [ -z "${store:-}" ] || [ "$store" = - ]; then
    warn "object store" "no barman-cloud plugin on the cluster"
  else
    IFS=$'\t' read -r first last_ok last_failed < <(K "$WRITER" get objectstores.barmancloud.cnpg.io "$store" -o json 2>/dev/null \
      | jq -r --arg s "$server" '.status.serverRecoveryWindow[$s] // {} | [.firstRecoverabilityPoint // "-", .lastSuccessfulBackupTime // "-", .lastFailedBackupTime // "-"] | @tsv')
    if [ -z "${last_ok:-}" ] || [ "$last_ok" = - ]; then
      fail "last successful backup" "none for server $server in $store"
    else
      age=$(( ($(date +%s) - $(epoch "$last_ok")) / 3600 ))
      [ "$age" -le "$MAX_BACKUP_AGE_H" ] && pass "last successful backup" "$last_ok (${age}h ago)" \
        || warn "last successful backup" "$last_ok (${age}h ago > ${MAX_BACKUP_AGE_H}h)"
      info "recovery window" "$first .. now ($store/$server)"
    fi
    if [ "${last_failed:-}" != - ] && [ -n "${last_failed:-}" ] && [ "$(epoch "$last_failed")" -gt "$(epoch "${last_ok:-1970-01-01}")" ]; then
      warn "no failed backup since" "failed at $last_failed"
    fi
  fi
  latest=$(K "$WRITER" get backups.postgresql.cnpg.io -o json 2>/dev/null | jq -r --arg c "$C" '
    [.items[] | select(.spec.cluster.name == $c)] | sort_by(.metadata.creationTimestamp) | last // empty
    | [.metadata.name, .status.phase // "pending", .status.error // ""] | @tsv')
  if [ -n "$latest" ]; then
    IFS=$'\t' read -r bname bphase berr <<<"$latest"
    case $bphase in
      completed) pass "latest Backup" "$bname $bphase" ;;
      failed) warn "latest Backup" "$bname failed: $berr" ;;
      *) info "latest Backup" "$bname $bphase" ;;
    esac
  fi
  while IFS=$'\t' read -r sname suspended next; do
    [ -n "$sname" ] || continue
    [ "$suspended" = true ] && warn "scheduled backup $sname" "suspended" || pass "scheduled backup $sname" "next $next"
  done < <(K "$WRITER" get scheduledbackups.postgresql.cnpg.io -o json 2>/dev/null \
    | jq -r --arg c "$C" '.items[] | select(.spec.cluster.name == $c) | [.metadata.name, .spec.suspend // false, .status.nextScheduleTime // "-"] | @tsv')
else
  section "geo replication and backups"
  warn "skipped" "needs exactly one writing location"
fi

### Probe: a row written on the writing side shows up in every instance of both locations

if [ -n "${PROBE:-}" ] && [ -n "$WRITER" ]; then
  section "probe (write in $WRITER, read everywhere)"
  token="hc-$(date +%s)-$RANDOM"
  if psql_at "$WRITER" "${PRIMARY[$WRITER]}" \
      "create table if not exists healthcheck_probe (token text primary key, at timestamptz not null default now())" \
      "delete from healthcheck_probe where at < now() - interval '1 day'" \
      "insert into healthcheck_probe (token) values ('$token')" \
      "select pg_switch_wal()" >/dev/null; then
    pass "write in $WRITER" "$token"
    targets=()
    for loc in "${REACHABLE[@]}"; do
      for p in $(K "$loc" get pods -l cnpg.io/cluster="$C" -o name 2>/dev/null); do
        [ "$loc/${p#pod/}" = "$WRITER/${PRIMARY[$WRITER]}" ] || targets+=("$loc/${p#pod/}")
      done
    done
    start=$(date +%s)
    while [ ${#targets[@]} -gt 0 ] && [ $(( $(date +%s) - start )) -lt "$PROBE_TIMEOUT" ]; do
      left=()
      for t in "${targets[@]}"; do
        if [ "$(psql_at "${t%%/*}" "${t#*/}" "select 1 from healthcheck_probe where token = '$token'")" = 1 ]; then
          pass "row on $t" "after $(( $(date +%s) - start ))s"
        else left+=("$t"); fi
      done
      targets=("${left[@]}")
      [ ${#targets[@]} -gt 0 ] && sleep 5
    done
    for t in "${targets[@]}"; do fail "row on $t" "not there after ${PROBE_TIMEOUT}s"; done
  else
    fail "write in $WRITER" "insert failed on ${PRIMARY[$WRITER]}"
  fi
elif [ -z "${PROBE:-}" ]; then
  echo; echo "${D}(PROBE=1 also writes a row in the writing location and waits for it everywhere)${N}"
fi

echo
printf "%s passed, %s warnings, %s failed\n" "${G}$PASSES${N}" "${Y}$WARNS${N}" "${R}$FAILS${N}"
[ "$FAILS" -gt 0 ] && exit 2
[ "$WARNS" -gt 0 ] && exit 1
exit 0

# Commands that change the cluster; run them by hand.
#
# switchover between locations (planned) or failover (protected location down): on the control plane
#   kubectl -n multi-region patch postgrescluster drtest --type merge -p '{"spec":{"geoReplication":{"primarySite":"recovery"}}}'
# switchover inside a location to a specific replica (cnpg)
#   kubectl cnpg --context protected -n multi-region promote drtest drtest-2
# rolling restart, replicas first and the primary last (cnpg)
#   kubectl cnpg --context protected -n multi-region restart drtest
# fence / unfence an instance
#   kubectl --context protected -n multi-region annotate cluster drtest cnpg.io/fencedInstances='["drtest-1"]' --overwrite
#   kubectl --context protected -n multi-region annotate cluster drtest cnpg.io/fencedInstances-
# PgBouncer pause / resume
#   kubectl --context protected -n multi-region patch pooler drtest-pooler-rw --type merge -p '{"spec":{"pgbouncer":{"paused":true}}}'
#   kubectl --context protected -n multi-region patch pooler drtest-pooler-rw --type merge -p '{"spec":{"pgbouncer":{"paused":false}}}'
# drop the probe table
#   kubectl --context <writing> -n multi-region exec <primary> -c postgres -- psql -c 'drop table healthcheck_probe'
