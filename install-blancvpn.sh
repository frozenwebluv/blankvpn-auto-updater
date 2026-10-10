#!/bin/sh
# BlancVPN 0.1.0-rc.3 — standalone installer for Keenetic / Entware / XKeen.
# Includes the complete program; no code is downloaded.
set -eu
umask 077
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router' >&2; exit 1; }
command -v mktemp >/dev/null 2>&1 || { echo 'Required command missing: mktemp' >&2; exit 1; }
[ ! -e /opt/sbin/blancvpn ] || {
    echo 'BlancVPN is already installed. Check: /opt/sbin/blancvpn version' >&2
    echo 'Existing settings, Xray files and cron were kept.' >&2
    exit 1
}
stage=$(mktemp -d /tmp/blancvpn-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$stage/lib"
cat > "$stage/install.sh" <<'BLANCVPN_EMBEDDED_FILE_0_END'
#!/bin/sh
# Local installer: never downloads code and never changes Xray or cron.
set -eu
umask 077
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router' >&2; exit 1; }
for cmd in jq awk curl base64 timeout mktemp pidof crontab xray xkeen; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command missing: $cmd" >&2; exit 1; }
done
jq -ne '"ok"|IN("ok")' >/dev/null 2>&1 || { echo 'jq 1.6 or newer is required' >&2; exit 1; }
jq -ne '"ok"|test("^ok$")' >/dev/null 2>&1 || { echo 'jq needs regex support. On Entware replace jq with jq-full; see README.' >&2; exit 1; }
[ ! -e /opt/sbin/blancvpn ] || { echo 'Already installed. This first-release installer does not overwrite existing versions.' >&2; exit 1; }
base=$(CDPATH='' cd "$(dirname "$0")" && pwd)
for f in blancvpn lib/uri.awk lib/nodes.jq lib/merge.jq lib/jsonc.awk; do
    [ -f "$base/$f" ] || { echo 'Incomplete distribution' >&2; exit 1; }
done
mkdir -p /opt/share/blancvpn/lib /opt/sbin
for f in uri.awk nodes.jq merge.jq jsonc.awk; do
    cp "$base/lib/$f" "/opt/share/blancvpn/lib/$f.new"
    chmod 644 "/opt/share/blancvpn/lib/$f.new"
    mv "/opt/share/blancvpn/lib/$f.new" "/opt/share/blancvpn/lib/$f"
done
cp "$base/blancvpn" /opt/sbin/blancvpn.new
chmod 755 /opt/sbin/blancvpn.new
mv /opt/sbin/blancvpn.new /opt/sbin/blancvpn
/opt/sbin/blancvpn init
echo 'Installed. Next: blancvpn set-url; blancvpn preview. Xray was not restarted.'
BLANCVPN_EMBEDDED_FILE_0_END
cat > "$stage/blancvpn" <<'BLANCVPN_EMBEDDED_FILE_1_END'
#!/bin/sh
# BlancVPN 0.1.0-rc.3. POSIX shell; configuration and subscription are data, not code.
set +x
set -u
umask 077
PATH="${BLANCVPN_PATH:-/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH
VERSION=0.1.0-rc.3
STATE=${BLANCVPN_STATE_DIR:-/opt/etc/blancvpn}
CONF=${BLANCVPN_CONFIG_DIR:-/opt/etc/xray/configs}
XRAY=${BLANCVPN_XRAY_BIN:-xray}
XKEEN=${BLANCVPN_XKEEN_BIN:-xkeen}
SELF_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
LIB=${BLANCVPN_LIB_DIR:-$SELF_DIR/lib}
[ -d "$LIB" ] || LIB=/opt/share/blancvpn/lib
WORK='' LOCKED=0 TX_ACTIVE=0 TX_ID='' ECHO_STATE=''

say() { printf '%s\n' "$*"; }
die() { log "error: $*" || :; printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
log() {
    [ -d "$STATE" ] || return 0
    if [ -f "$STATE/events.log" ] && [ "$(wc -c < "$STATE/events.log")" -gt 262144 ]; then
        mv "$STATE/events.log" "$STATE/events.log.1" || return 1
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$STATE/events.log"
}
private_dirs() {
    case "$STATE" in /*) ;; *) die 'State directory must be absolute';; esac
    [ "$STATE" != / ] || die 'Invalid state directory'
    for d in "$STATE" "$STATE/work" "$STATE/backups"; do
        [ ! -L "$d" ] || die 'State directories must not be symlinks'
        mkdir -p "$d" && chmod 700 "$d" || die 'Cannot create private state directory'
    done
}
jq_requirements() {
    need jq
    jq -ne '"ok"|IN("ok")' >/dev/null 2>&1 || die 'jq 1.6 or newer is required'
    jq -ne '"ok"|test("^ok$")' >/dev/null 2>&1 || die 'jq needs regex support; on Entware replace jq with jq-full'
}
json_read() {
    awk -f "$LIB/jsonc.awk" "$1" | jq -e 'if type=="object" then . else error("Xray config must be an object") end'
}
valid_config() {
    jq -e 'type=="object" and .version==1
      and (.nodes|type=="number" and floor==. and .>=1 and .<=32)
      and (.strategy|IN("leastPing","leastLoad")) and (.fallback|IN("block","direct"))
      and (.hours|IN(1,2,3,4,6,8,12,24))
      and (.inbound_tags|type=="array" and length>0 and length<=16 and (unique|length)==length
        and all(.[];type=="string" and test("^[A-Za-z0-9_-]{1,64}$")))
      and (.probe_url|type=="string" and test("^https://[^[:space:]]+$") and (test("[\u0000-\u001f\u007f]")|not))' "$1" >/dev/null 2>&1
}
load_config() {
    jq_requirements
    [ -f "$STATE/config.json" ] || die 'Run init first'
    valid_config "$STATE/config.json" || die 'Invalid config.json; see README'
    C=$(cat "$STATE/config.json")
    NODES=$(jq -r '.nodes' "$STATE/config.json")
    STRATEGY=$(jq -r '.strategy' "$STATE/config.json")
    HOURS=$(jq -r '.hours' "$STATE/config.json")
}
lock() {
    private_dirs
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        say 'Busy: another operation or a stale lock exists; inspect status / unlock' >&2
        exit 75
    fi
    LOCKED=1
    printf '%s\n' "$$" > "$STATE/lock/pid" || die 'Cannot record lock ownership'
    WORK=$(mktemp -d "$STATE/work/run.XXXXXX") || die 'Cannot create private workspace'
    printf '%s\n' "$$" > "$WORK/owner.pid" || die 'Cannot record workspace owner'
    [ ! -e "$STATE/pending.json" ] || [ "${CMD:-}" = recover ] || die 'Interrupted transaction: run recover before making changes'
}
restore_snapshot() {
    b="$STATE/backups/$1"
    [ -f "$b/manifest.json" ] || return 1
    jq -e '(.targets|type=="array" and length>0 and all(.[];test("^[A-Za-z0-9_-]+[.]json$")))
      and (.existing|type=="array")' "$b/manifest.json" >/dev/null 2>&1 || return 1
    for name in $(jq -r '.targets[]' "$b/manifest.json"); do
        if jq -e --arg name "$name" '.existing|index($name)!=null' "$b/manifest.json" >/dev/null; then
            [ -f "$b/configs/$name" ] && [ ! -L "$CONF/$name" ] || return 1
            cp "$b/configs/$name" "$CONF/$name.blancvpn-tmp" && mv "$CONF/$name.blancvpn-tmp" "$CONF/$name" || return 1
        else
            rm -f "$CONF/$name" || return 1
        fi
    done
    if [ -f "$b/metadata.json" ]; then
        cp "$b/metadata.json" "$STATE/metadata.json.tmp" && mv "$STATE/metadata.json.tmp" "$STATE/metadata.json" || return 1
    else
        rm -f "$STATE/metadata.json" || return 1
    fi
}
restart() {
    timeout 60 "$XKEEN" -restart > "$WORK/service-output" 2>&1 || return 1
    pidof xray >/dev/null 2>&1 || return 1
    wait_s=${BLANCVPN_HEALTH_WAIT:-3}
    case "$wait_s" in 0|1|2|3|4|5) ;; *) wait_s=3;; esac
    sleep "$wait_s"
    pidof xray >/dev/null 2>&1
}
cleanup() {
    rc=$?
    trap - 0 HUP INT TERM
    [ -z "$ECHO_STATE" ] || stty "$ECHO_STATE" 2>/dev/null
    if [ "$TX_ACTIVE" = 1 ]; then
        if restore_snapshot "$TX_ID" && restart; then
            rm -f "$STATE/pending.json"
            log "rollback-success backup=$TX_ID"
            prune_backups || :
        else
            log "rollback-incomplete backup=$TX_ID; run recover"
            say 'ERROR: rollback incomplete; pending journal retained. Run recover.' >&2
        fi
        rc=1
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ "$LOCKED" = 1 ] && [ "$(cat "$STATE/lock/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$STATE/lock/pid"
        rmdir "$STATE/lock" 2>/dev/null || :
    fi
    exit "$rc"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

read_cron() {
    crontab -l > "$1" 2>/dev/null
    rc=$?
    case "$rc" in 0) ;; 1) : > "$1";; *) die 'Cannot read crontab';; esac
}
has_legacy() { grep -Eq '(^|[[:space:]/])blanc-auto-update([[:space:]]|$)' "$1"; }
runtime_requirements() {
    for c in jq curl base64 awk timeout pidof crontab cmp mktemp; do need "$c"; done
    need "$XRAY"; need "$XKEEN"
    for file in uri.awk nodes.jq merge.jq jsonc.awk; do [ -f "$LIB/$file" ] || die 'Incomplete package: library missing'; done
    [ -d "$CONF" ] || die 'Xray configuration directory missing'
    for f in "$CONF"/*.json; do
        [ -f "$f" ] || die 'Xray configuration directory has no JSON files'
        [ ! -L "$f" ] || die 'Symlinked Xray JSON files are not supported'
        json_read "$f" >/dev/null 2>&1 || die "Invalid Xray JSON/comment syntax in ${f##*/}"
    done
    read_cron "$WORK/cron"
    if [ "$CMD" != preview ] && has_legacy "$WORK/cron"; then
        die 'Legacy updater is scheduled. Preview first, then run schedule disable-legacy explicitly'
    fi
}
read_subscription() {
    [ -f "$STATE/subscription.url" ] && [ ! -L "$STATE/subscription.url" ] || die 'Set subscription with set-url first'
    # curl config quoting uses JSON escaping; URL never enters process arguments.
    jq -Rs 'select(test("^https://[^[:space:]]+$") and (test("[\u0000-\u001f\u007f]")|not))' "$STATE/subscription.url" > "$WORK/url.json" || die 'Cannot read subscription URL'
    [ -s "$WORK/url.json" ] || die 'Subscription must be a single HTTPS URL'
    { printf 'url = '; cat "$WORK/url.json"; } > "$WORK/curl.conf"
    curl -q --config "$WORK/curl.conf" --proto '=https' --proto-redir '=https' --location --fail --silent --show-error \
        --connect-timeout 15 --max-time 45 --retry 2 --max-filesize 2097152 -o "$WORK/body" > "$WORK/download-output" 2>&1 \
        || die 'Subscription download failed (HTTP/TLS/timeout); active configuration kept'
    [ "$(wc -c < "$WORK/body")" -le 2097152 ] || die 'Subscription exceeds 2 MiB limit'
    [ -s "$WORK/body" ] || die 'Empty subscription'
    normalize_subscription "$WORK/body"
}
normalize_subscription() {
    input=$1
    # JSON object with outbounds, or a bare JSON array.
    if jq -e '(type=="object" and (.outbounds|type=="array")) or type=="array"' "$input" >/dev/null 2>&1; then
        jq 'if type=="array" then . else .outbounds end' "$input" > "$WORK/source.json" || die 'Invalid JSON subscription'
        FORMAT=json
    elif grep -q '^vless://' "$input"; then
        awk -f "$LIB/uri.awk" "$input" > "$WORK/records" 2> "$WORK/parser-stats" || die 'URI parser failed'
        jq -s '.' "$WORK/records" > "$WORK/source.json" || die 'URI parser produced invalid data'
        FORMAT=uri
    elif [ "$input" = "$WORK/body" ]; then
        # Also accepts unpadded base64url. No decoder errors are exposed to logs.
        tr -d ' \t\r\n' < "$input" | tr '_-' '/+' > "$WORK/base64"
        size=$(wc -c < "$WORK/base64")
        case $((size % 4)) in 2) printf '==' >> "$WORK/base64";; 3) printf '=' >> "$WORK/base64";; 1) die 'Invalid base64 subscription';; esac
        base64 -d < "$WORK/base64" > "$WORK/decoded" 2>/dev/null || die 'Subscription is neither supported JSON, URI text nor base64'
        normalize_subscription "$WORK/decoded"
        return
    else
        die 'Decoded subscription has no supported JSON or VLESS URI records'
    fi
    jq --arg format "$FORMAT" --argjson count "$NODES" -f "$LIB/nodes.jq" "$WORK/source.json" > "$WORK/nodes.json" 2> "$WORK/parser-errors" \
        || die 'Not enough supported distinct Extra nodes; only VLESS TCP/RAW REALITY is supported'
    TOTAL=$(jq 'length' "$WORK/source.json")
    say "Subscription records=$TOTAL; selected=$NODES; format=$FORMAT"
}
canon() { json_read "$1" > "$WORK/read-json" && jq -S '.' "$WORK/read-json"; }
same_json() { canon "$1" > "$WORK/canon-a" && canon "$2" > "$WORK/canon-b" && cmp -s "$WORK/canon-a" "$WORK/canon-b"; }
merge_file() {
    mode=$1; name=$2
    [ -f "$WORK/stage/$name" ] || printf '{}\n' > "$WORK/stage/$name"
    jq --arg mode "$mode" --argjson c "$C" --slurpfile nodes "$WORK/nodes.json" -f "$LIB/merge.jq" "$WORK/stage/$name" > "$WORK/merged" 2> "$WORK/merge-errors" \
        || die 'Configuration merge rejected; inspect overlapping defaults, fallback outbound or observer compatibility'
    mv "$WORK/merged" "$WORK/stage/$name" || die 'Cannot stage configuration'
}
validate_stage() {
    jq -se --argjson c "$C" '
      [.[].outbounds[]?] as $o | [.[].inbounds[]?] as $i
      | ($o|all(.[];(.tag|type=="string" and length>0)))
        and (($o|map(.tag)|unique|length)==($o|length))
        and (($i|map(.tag)|unique|length)==($i|length))
        and all($c.inbound_tags[]; . as $tag | any($i[];.tag==$tag))
        and ([$o[]|select(.tag|startswith("blancvpn-node-"))]|length)==$c.nodes
        and all($o[]|select(.tag|startswith("blancvpn-node-"));.protocol=="vless")' "$WORK/stage"/*.json >/dev/null 2>&1 \
        || die 'Duplicate/missing outbound or inbound tags; stage rejected'
    timeout 30 "$XRAY" run -test -confdir "$WORK/stage" > "$WORK/xray-output" 2>&1 || die 'Xray rejected staged config; active files were not changed'
}
build() {
    mkdir "$WORK/stage" || die 'Cannot create stage'
    for f in "$WORK/original"/*.json; do
        json_read "$f" > "$WORK/stage/${f##*/}" 2>/dev/null || die 'Cannot stage Xray configuration'
    done
    ACTIVE=false
    [ ! -f "$STATE/metadata.json" ] || ACTIVE=$(jq -r '.active // false' "$STATE/metadata.json")
    if [ "$ACTIVE" != true ]; then
        jq -se 'all(.[];all(.outbounds[]?,.routing.balancers[]?,.routing.rules[]?;
          ((.tag // .balancerTag // .ruleTag // "")|startswith("blancvpn-")|not)))' "$WORK/stage"/*.json >/dev/null 2>&1 \
            || die 'Reserved blancvpn- names already exist; do not take over another installation'
    fi
    observer=07_observatory.json; observers=0
    for f in "$WORK/stage"/*.json; do
        name=${f##*/}
        if [ "$name" != 05_routing.json ] && jq -e '.routing!=null' "$f" >/dev/null; then
            die 'Routing must be in 05_routing.json only; split routing needs manual consolidation'
        fi
        if jq -e '.observatory!=null or .burstObservatory!=null' "$f" >/dev/null; then
            observer=$name; observers=$((observers+1))
        fi
        if [ "$name" != 04_outbounds.json ] && jq -e 'any(.outbounds[]?;.tag|startswith("blancvpn-"))' "$f" >/dev/null; then
            die 'Managed outbound names in another file; refusing ambiguous ownership'
        fi
    done
    [ "$observers" -le 1 ] || die 'Multiple observer definitions; consolidate manually first'
    printf '%s\n' 04_outbounds.json 05_routing.json "$observer" | sort -u > "$WORK/targets"
    merge_file outbounds 04_outbounds.json
    merge_file routing 05_routing.json
    if [ "$observers" = 1 ]; then
        want=observatory; [ "$STRATEGY" != leastLoad ] || want=burstObservatory
        if ! jq -e --arg want "$want" '.[$want]!=null' "$WORK/stage/$observer" >/dev/null; then
            jq -se '[.[].routing.rules[]?|.balancerTag // empty] as $used
              | all(.[].routing.balancers[]?;(.tag|startswith("blancvpn-"))
                or ((.strategy.type // "random")|IN("random","roundRobin"))
                or (.tag as $tag|$used|index($tag)==null))' "$WORK/stage"/*.json >/dev/null \
                || die 'Observer change could affect another balancer; keep the existing strategy or adjust manually'
        fi
    fi
    merge_file observer "$observer"
    validate_stage
}
snapshot() {
    TX_ID="$(date '+%Y%m%d-%H%M%S')-$$"
    b="$STATE/backups/$TX_ID"
    mkdir "$b" "$b/configs" || die 'Cannot create snapshot'
    cp "$CONF"/*.json "$b/configs/" || die 'Cannot save full configuration snapshot'
    [ ! -f "$STATE/metadata.json" ] || cp "$STATE/metadata.json" "$b/metadata.json" || die 'Cannot save metadata'
    jq -Rn '[inputs]' < "$WORK/targets" > "$WORK/targets.json"
    for name in $(cat "$WORK/targets"); do [ ! -f "$CONF/$name" ] || say "$name"; done > "$WORK/existing"
    jq -Rn '[inputs]' < "$WORK/existing" > "$WORK/existing.json"
    jq -n --slurpfile t "$WORK/targets.json" --slurpfile e "$WORK/existing.json" '{targets:$t[0],existing:$e[0]}' > "$b/manifest.json" || die 'Cannot save manifest'
}
unchanged_since_snapshot() {
    # Detect edits in any config made by a panel/watchdog while stage was being tested.
    for f in "$CONF"/*.json; do
        name=${f##*/}; [ -f "$WORK/original/$name" ] && cmp -s "$f" "$WORK/original/$name" || return 1
    done
    for f in "$WORK/original"/*.json; do [ -f "$CONF/${f##*/}" ] || return 1; done
}
expected() {
    : > "$WORK/expected-records"
    for name in $(cat "$WORK/targets"); do
        if [ -f "$CONF/$name" ]; then
            json_read "$CONF/$name" > "$WORK/read-json" && jq --arg name "$name" '{key:$name,value:.}' "$WORK/read-json" >> "$WORK/expected-records" || return 1
        else jq -n --arg name "$name" '{key:$name,value:null}' >> "$WORK/expected-records"; fi
    done
    jq -s 'from_entries' "$WORK/expected-records"
}
prune_backups() {
    # Keep only the initial configuration for deactivate. Transaction snapshots
    # remain on disk until commit/recovery succeeds; no update history is kept.
    [ ! -e "$STATE/pending.json" ] || return 0
    pinned=''
    if [ -f "$STATE/metadata.json" ]; then
        pinned=$(jq -r '.initial_backup // empty' "$STATE/metadata.json") || return 1
        jq 'del(.last_backup)' "$STATE/metadata.json" > "$STATE/metadata.json.tmp" \
            && mv "$STATE/metadata.json.tmp" "$STATE/metadata.json" || return 1
    fi
    for path in "$STATE/backups"/*; do
        [ -d "$path" ] && [ ! -L "$path" ] || continue
        id=${path##*/}
        case "$id" in *[!0-9-]*|'') continue;; esac
        [ "$id" = "$pinned" ] || rm -rf "$path" || return 1
    done
}

commit() {
    changed=0
    for name in $(cat "$WORK/targets"); do
        [ -f "$CONF/$name" ] && [ -f "$WORK/stage/$name" ] && same_json "$CONF/$name" "$WORK/stage/$name" || changed=1
    done
    if [ "$changed" = 0 ]; then
        prune_backups || die 'Cannot remove old update history'
        log 'unchanged; no restart'; say 'No configuration change; no restart'; return
    fi
    unchanged_since_snapshot || die 'Configuration changed during preview/test; retry after stopping concurrent edits'
    snapshot
    initial="$TX_ID"
    drift=false
    if [ -f "$STATE/metadata.json" ] && [ "$(jq -r .active "$STATE/metadata.json")" = true ]; then
        initial=$(jq -r '.initial_backup // empty' "$STATE/metadata.json")
        drift=$(jq -r '.externally_edited // false' "$STATE/metadata.json")
        jq -r '.expected|keys[]' "$STATE/metadata.json" > "$WORK/prior-targets"
        for name in $(cat "$WORK/prior-targets"); do
            jq --arg name "$name" '.expected[$name]' "$STATE/metadata.json" > "$WORK/prior-file"
            [ -f "$CONF/$name" ] && same_json "$CONF/$name" "$WORK/prior-file" || drift=true
        done
    fi
    [ -n "$initial" ] || initial="$TX_ID"
    jq -n --arg id "$TX_ID" '{backup_id:$id}' > "$STATE/pending.json.tmp" && mv "$STATE/pending.json.tmp" "$STATE/pending.json" || die 'Cannot write transaction journal'
    TX_ACTIVE=1
    sync
    for name in $(cat "$WORK/targets"); do
        if [ -f "$WORK/stage/$name" ]; then
            cp "$WORK/stage/$name" "$CONF/$name.blancvpn-tmp" && mv "$CONF/$name.blancvpn-tmp" "$CONF/$name" || die 'Cannot apply config; rollback requested'
        else rm -f "$CONF/$name" || die 'Cannot restore absent file'; fi
    done
    restart || die 'Service did not survive restart; rolling back'
    expected > "$WORK/expected.json" || die 'Cannot record applied configuration'
    jq -n --arg initial "$initial" --arg time "$(date '+%Y-%m-%dT%H:%M:%S%z')" --argjson active "$NEW_ACTIVE" --argjson drift "$drift" --slurpfile e "$WORK/expected.json" \
        '{active:$active,initial_backup:$initial,last_applied:$time,externally_edited:$drift,expected:$e[0]}' > "$STATE/metadata.json.tmp" \
        && mv "$STATE/metadata.json.tmp" "$STATE/metadata.json" || die 'Cannot save state; rolling back'
    sync
    TX_ACTIVE=0
    rm -f "$STATE/pending.json" || die 'Cannot finalize transaction; run recover'
    log "apply-success backup=$TX_ID"
    prune_backups || log 'backup pruning failed; inspect storage'
    say 'Applied; Xray process is running. Update history is not stored.'
}
start_work() {
    load_config; lock; runtime_requirements
    mkdir "$WORK/original" && cp "$CONF"/*.json "$WORK/original/" || die 'Cannot capture original configs'
}
summary() {
    say "Strategy=$STRATEGY; fallback=$(jq -r .fallback "$STATE/config.json"); interval=${HOURS}h"
    say 'Proposed rule order (node credentials omitted):'
    jq -r '.routing.rules|to_entries[]|"  \(.key+1). \(.value.balancerTag // .value.outboundTag // "unknown") [inbounds=\((.value.inboundTag // ["all"])|join(",")); conditional=\((.value|has("domain") or has("ip") or has("port") or has("protocol")))]"' "$WORK/stage/05_routing.json"
    say 'Stage accepted by Xray. Preview does not restart or apply files.'
}
usage() {
    cat <<'EOF'
blancvpn 0.1.0-rc.3 — Keenetic / Entware / XKeen
  init                         Create private configuration only
  set-url                      Read HTTPS subscription URL from stdin (hidden on TTY)
  configure [options]          --nodes N --strategy leastPing|leastLoad
                               --fallback block|direct --hours H
                               --inbounds redirect,tproxy --probe-url HTTPS_URL
  preview                      Download, merge and test without applying
  activate                     Activate after preview; legacy cron must be disabled
  update                       Update an already active installation
  status                       Show non-secret state
  schedule enable|disable      Manage this utility's cron entry
  schedule disable-legacy      Back up cron, remove the old blanc-auto-update job
  recover                      Restore interrupted transaction and restart
  unlock                       Remove lock only if its recorded PID is dead
  rollback BACKUP_ID           Test and restore targeted files from a snapshot
  deactivate                   Restore initial files if nobody edited managed files
  version | help
EOF
}
CMD=${1:-help}; [ "$#" = 0 ] || shift
case "$CMD" in
help|--help|-h) usage;;
version|--version) say "$VERSION";;
init)
    jq_requirements; lock
    if [ ! -f "$STATE/config.json" ]; then
        printf '%s\n' '{"version":1,"nodes":6,"strategy":"leastPing","fallback":"block","hours":6,"inbound_tags":["redirect","tproxy"],"probe_url":"https://www.gstatic.com/generate_204"}' > "$STATE/config.json" || die 'Cannot write config'
    fi
    say 'Initialized; no Xray files or cron entries changed';;
set-url)
    need jq; load_config; lock
    if [ -t 0 ]; then
        ECHO_STATE=$(stty -g); stty -echo
        printf 'HTTPS subscription URL (hidden): ' >&2
    fi
    URL=; IFS= read -r URL || :
    [ -z "$ECHO_STATE" ] || { stty "$ECHO_STATE"; ECHO_STATE=; printf '\n' >&2; }
    printf '%s' "$URL" > "$WORK/url"
    jq -Rse 'test("^https://[^[:space:]]+$") and (test("[\u0000-\u001f\u007f]")|not)' "$WORK/url" >/dev/null || die 'Expected a single HTTPS URL'
    mv "$WORK/url" "$STATE/subscription.url" || die 'Cannot store subscription'
    unset URL
    say 'Subscription saved privately; no download or restart';;
configure)
    need jq; load_config; lock
    printf '%s\n' "$C" > "$WORK/config"
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || die 'Option needs a value'
        option=$1; value=$2; shift 2
        case "$option" in
          --nodes) key=nodes; kind=number;; --hours) key=hours; kind=number;;
          --strategy) key=strategy; kind=string;; --fallback) key=fallback; kind=string;;
          --probe-url) key=probe_url; kind=string;; --inbounds) key=inbound_tags; kind=array;;
          *) die 'Unknown configure option';;
        esac
        jq --arg key "$key" --arg value "$value" --arg kind "$kind" '.[$key]=(if $kind=="number" then ($value|tonumber) elif $kind=="array" then ($value|split(",")) else $value end)' "$WORK/config" > "$WORK/config.new" 2>/dev/null || die 'Invalid option value'
        mv "$WORK/config.new" "$WORK/config"
    done
    valid_config "$WORK/config" || die 'Invalid settings; supported values are in help/README'
    mv "$WORK/config" "$STATE/config.json" || die 'Cannot save settings'
    say 'Settings saved; preview recommended before the next update';;
preview|activate|update)
    start_work
    if [ "$CMD" = update ]; then
        [ -f "$STATE/metadata.json" ] && [ "$(jq -r '.active' "$STATE/metadata.json")" = true ] || die 'Not active; use preview then activate'
    fi
    read_subscription; build
    if [ "$CMD" = preview ]; then summary; else NEW_ACTIVE=true; commit; fi;;
status)
    need jq; load_config
    say "blancvpn $VERSION"
    jq '{nodes,strategy,fallback,hours,inbound_tags}' "$STATE/config.json"
    [ ! -f "$STATE/metadata.json" ] || jq 'del(.expected)' "$STATE/metadata.json"
    [ ! -e "$STATE/pending.json" ] || say 'ATTENTION: pending transaction; recover required'
    [ ! -d "$STATE/lock" ] || say 'Lock exists; another operation may be running'
    if pidof xray >/dev/null 2>&1; then say 'Xray process: running'; else say 'Xray process: not confirmed'; fi
    [ ! -f "$STATE/events.log" ] || tail -n 8 "$STATE/events.log";;
schedule)
    need jq; need crontab; load_config; lock
    action=${1:-}; read_cron "$WORK/cron"
    case "$action" in
      enable)
        [ -f "$STATE/metadata.json" ] && [ "$(jq -r .active "$STATE/metadata.json")" = true ] || die 'Activate before enabling cron'
        has_legacy "$WORK/cron" && die 'Disable legacy updater explicitly first'
        grep -v '# blancvpn-managed$' "$WORK/cron" > "$WORK/cron.new" || :
        say "17 */$HOURS * * * /opt/sbin/blancvpn update >/dev/null 2>&1 # blancvpn-managed" >> "$WORK/cron.new";;
      disable) grep -v '# blancvpn-managed$' "$WORK/cron" > "$WORK/cron.new" || :;;
      disable-legacy) awk '!/(^|[[:space:]\/])blanc-auto-update([[:space:]]|$)/' "$WORK/cron" > "$WORK/cron.new";;
      *) die 'Use schedule enable, disable or disable-legacy';;
    esac
    read_cron "$WORK/cron.latest"
    cmp -s "$WORK/cron" "$WORK/cron.latest" || die 'Crontab changed concurrently; retry'
    if [ ! -f "$STATE/backups/crontab.original" ]; then
        cp "$WORK/cron" "$STATE/backups/crontab.original" || die 'Cannot save initial crontab'
    fi
    crontab "$WORK/cron.new" || die 'Cannot install crontab'
    log "schedule-$action"
    say "Cron $action completed; other jobs preserved. --hours takes effect on schedule enable.";;
unlock)
    [ -f "$STATE/lock/pid" ] || die 'No recorded lock PID; inspect manually'
    owner=$(cat "$STATE/lock/pid")
    case "$owner" in ''|*[!0-9]*) die 'Invalid recorded PID; inspect manually';; esac
    kill -0 "$owner" 2>/dev/null && die 'Recorded process is alive; lock was kept'
    rm -f "$STATE/lock/pid" && rmdir "$STATE/lock" || die 'Cannot remove stale lock'
    for d in "$STATE/work"/run.*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        [ "$(cat "$d/owner.pid" 2>/dev/null)" != "$owner" ] || rm -rf "$d"
    done
    say 'Dead-process lock removed; recover any pending transaction next';;
recover)
    need jq; need timeout; need pidof; need "$XKEEN"; load_config; lock
    [ -f "$STATE/pending.json" ] || { say 'No interrupted transaction'; exit 0; }
    id=$(jq -r '.backup_id' "$STATE/pending.json")
    case "$id" in *[!0-9-]*|'') die 'Invalid journal';; esac
    restore_snapshot "$id" && restart || die 'Recovery failed; journal retained'
    rm -f "$STATE/pending.json" || die 'Cannot clear journal'
    prune_backups || log 'temporary snapshot cleanup failed'
    log "recovery-success backup=$id"
    say 'Previous configuration restored; Xray process running';;
rollback|deactivate)
    start_work
    [ -f "$STATE/metadata.json" ] || die 'No activation metadata'
    if [ "$CMD" = deactivate ]; then
        [ "$(jq -r '.externally_edited // false' "$STATE/metadata.json")" = false ] || die 'External edits were detected earlier; use an explicitly reviewed rollback instead'
        id=$(jq -r '.initial_backup' "$STATE/metadata.json")
        jq -r '.expected|keys[]' "$STATE/metadata.json" > "$WORK/check-targets"
        for name in $(cat "$WORK/check-targets"); do
            jq --arg name "$name" '.expected[$name]' "$STATE/metadata.json" > "$WORK/expected-file"
            if [ -f "$CONF/$name" ]; then same_json "$CONF/$name" "$WORK/expected-file" || die 'Managed files were edited externally; deactivate refuses to overwrite them';
            else [ "$(cat "$WORK/expected-file")" = null ] || die 'Managed file missing; review snapshot manually'; fi
        done
        NEW_ACTIVE=false
    else id=${1:-}; NEW_ACTIVE=true; fi
    case "$id" in *[!0-9-]*|'') die 'Provide a backup ID from status/events.log';; esac
    b="$STATE/backups/$id"
    [ -f "$b/manifest.json" ] || die 'Snapshot not found'
    jq -e '.targets|type=="array" and length>0 and all(.[];test("^[A-Za-z0-9_-]+[.]json$"))' "$b/manifest.json" >/dev/null || die 'Invalid snapshot manifest'
    mkdir "$WORK/stage" && cp "$CONF"/*.json "$WORK/stage/" || die 'Cannot stage restore'
    jq -r '.targets[]' "$b/manifest.json" > "$WORK/targets"
    for name in $(cat "$WORK/targets"); do
        if jq -e --arg name "$name" '.existing|index($name)!=null' "$b/manifest.json" >/dev/null; then
            cp "$b/configs/$name" "$WORK/stage/$name" || die 'Incomplete snapshot'
        else rm -f "$WORK/stage/$name"; fi
    done
    timeout 30 "$XRAY" run -test -confdir "$WORK/stage" > "$WORK/xray-output" 2>&1 || die 'Xray rejected restore; active files kept'
    # A pre-activation snapshot has no managed balancer: treat it as deactivation.
    : > "$WORK/restore-objects"
    for f in "$WORK/stage"/*.json; do
        json_read "$f" >> "$WORK/restore-objects" 2>/dev/null || die 'Invalid configuration in restore snapshot'
    done
    jq -se 'any(.[].routing.balancers[]?;.tag=="blancvpn-balancer")' "$WORK/restore-objects" >/dev/null || NEW_ACTIVE=false
    commit
    if [ "$NEW_ACTIVE" = false ]; then say 'Inactive. Disable its cron with: blancvpn schedule disable'; fi;;
*) usage >&2; exit 2;;
esac
BLANCVPN_EMBEDDED_FILE_1_END
cat > "$stage/lib/uri.awk" <<'BLANCVPN_EMBEDDED_FILE_2_END'
# Portable POSIX awk. Never print the input URI or its credentials in diagnostics.
function hex(c) { return index("0123456789abcdef", tolower(c))-1 }
function decode(s,    i,c,a,b,r) {
    r=""
    for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c=="%") {
            a=hex(substr(s,i+1,1)); b=hex(substr(s,i+2,1))
            if(i+2>length(s)||a<0||b<0||a*16+b<32||a*16+b==127) {bad=1;return ""}
            c=sprintf("%c",a*16+b); i+=2
        }
        r=r c
    }
    return r
}
function quote(s,    i,c,r) {
    r="\""
    for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c=="\\"||c=="\"") r=r "\\"
        r=r c
    }
    return r "\""
}
{
    sub(/\r$/, "")
    if($0 ~ /^[[:space:]]*$/) next
    if($0 !~ /^vless:\/\//) {ignored++;next}
    line=$0; bad=0
    pos=index(line,"#")
    if(!pos) {ignored++;next}
    label=decode(substr(line,pos+1)); line=substr(line,1,pos-1)
    if(bad||tolower(label)!~/extra$/) {ignored++;next}
    if(tolower(label)~/whitelist/) {whitelist++;next}
    if(line ~ /[[:cntrl:]]/ || label ~ /[[:cntrl:]]/) {invalid++;next}
    sub(/^vless:\/\//,"",line)
    pos=index(line,"@"); if(!pos){invalid++;next}
    uuid=decode(substr(line,1,pos-1)); line=substr(line,pos+1)
    pos=index(line,"?"); if(!pos){invalid++;next}
    server=substr(line,1,pos-1); query=substr(line,pos+1)
    if(substr(server,1,1)=="[") {
        pos=index(server,"]:"); if(!pos){invalid++;next}
        host=substr(server,2,pos-2); port=substr(server,pos+2)
    } else {
        if(split(server,parts,":")!=2){invalid++;next}
        host=parts[1];port=parts[2]
    }
    host=decode(host)
    # Clear arrays without the non-POSIX `delete array` extension.
    for(k in params) delete params[k]
    n=split(query,pairs,"&")
    for(i=1;i<=n;i++) {
        pos=index(pairs[i],"=")
        if(!pos){bad=1;break}
        key=decode(substr(pairs[i],1,pos-1)); value=decode(substr(pairs[i],pos+1))
        if(key in params){bad=1;break}
        params[key]=value
    }
    if(bad||port!~/^[0-9]+$/){invalid++;next}
    # Only parameters whose semantics are implemented are accepted.
    for(k in params)
        if(k!="type"&&k!="security"&&k!="sni"&&k!="pbk"&&k!="sid"&&k!="fp"&&k!="flow"&&k!="encryption"&&k!="spx"&&k!="headerType") bad=1
    if(("headerType" in params)&&params["headerType"]!="none") bad=1
    if(bad){invalid++;next}
    transport=params["type"];if(transport=="")transport="tcp"
    fp=params["fp"];if(fp=="")fp="chrome"
    enc=params["encryption"];if(enc=="")enc="none"
    printf "{\"label\":%s,\"uuid\":%s,\"host\":%s,\"port\":%s,\"network\":%s,\"security\":%s,\"sni\":%s,\"pbk\":%s,\"sid\":%s,\"fp\":%s,\"flow\":%s,\"encryption\":%s,\"spx\":%s}\n", quote(label),quote(uuid),quote(host),quote(port),quote(transport),quote(params["security"]),quote(params["sni"]),quote(params["pbk"]),quote(params["sid"]),quote(fp),quote(params["flow"]),quote(enc),quote(params["spx"])
}
END { print "URI records: ignored=" ignored+0 ", whitelist=" whitelist+0 ", malformed=" invalid+0 > "/dev/stderr" }
BLANCVPN_EMBEDDED_FILE_2_END
cat > "$stage/lib/nodes.jq" <<'BLANCVPN_EMBEDDED_FILE_3_END'
def valid_host: type == "string" and length > 0 and length < 254
  and test("^[A-Za-z0-9:.\u002d]+$") and (test("^eh[0-9]*\\.vk\\.ru$";"i")|not);
def eligible:
  (.label|type=="string") and (.label|test("Extra$";"i"))
  and (.label|test("whitelist";"i")|not);
def valid_node:
  .protocol == "vless"
  and (.settings.vnext|type=="array" and length==1)
  and (.settings.vnext[0].address|valid_host)
  and (.settings.vnext[0].port|type=="number" and floor==. and .>=1 and .<=65535)
  and (.settings.vnext[0].users|type=="array" and length==1)
  and (.settings.vnext[0].users[0].id|type=="string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
  and .settings.vnext[0].users[0].encryption=="none"
  and ((.settings.vnext[0].users[0].flow // "")|IN("","xtls-rprx-vision","xtls-rprx-vision-udp443"))
  and (.streamSettings.network|IN("tcp","raw"))
  and ((.streamSettings|keys)-["network","security","realitySettings"]|length)==0
  and .streamSettings.security=="reality"
  and (.streamSettings.realitySettings.serverName|valid_host)
  and (.streamSettings.realitySettings.publicKey|type=="string" and test("^[A-Za-z0-9_-]{43}$"))
  and ((.streamSettings.realitySettings.shortId // "")|type=="string" and test("^([0-9a-fA-F]{2}){0,8}$"))
  and ((.streamSettings.realitySettings.fingerprint // "chrome")|IN("chrome","firefox","safari","ios","android","edge","360","qq","random","randomized"))
  and ((.streamSettings.realitySettings.spiderX // "")|type=="string" and (test("[\u0000-\u001f\u007f]")|not));
def from_uri:
  {label,protocol:"vless",settings:{vnext:[{address:.host,port:(.port|tonumber),users:[{id:.uuid,encryption:.encryption,flow:.flow}]}]},
   streamSettings:{network:.network,security:.security,realitySettings:{serverName:.sni,publicKey:.pbk,shortId:.sid,fingerprint:.fp,spiderX:.spx}}};
# JSON subscriptions contribute node data only, never routing, DNS or socket settings.
def clean:
  {protocol:"vless",settings:{vnext:[{address:(.settings.vnext[0].address|ascii_downcase),port:.settings.vnext[0].port,
    users:[{id:(.settings.vnext[0].users[0].id|ascii_downcase),encryption:"none",flow:(.settings.vnext[0].users[0].flow // "")}]}]},
   streamSettings:{network:"tcp",security:"reality",realitySettings:{
    serverName:.streamSettings.realitySettings.serverName,publicKey:.streamSettings.realitySettings.publicKey,
    shortId:(.streamSettings.realitySettings.shortId // ""),fingerprint:(.streamSettings.realitySettings.fingerprint // "chrome"),
    spiderX:(.streamSettings.realitySettings.spiderX // "")}}};
(if $format=="uri" then . else . end) as $input
| [ $input[] | if $format=="uri" then (try from_uri catch empty) else . + {label:(.tag // "")} end
    | select(eligible) | select(try valid_node catch false) | clean ]
# Stable ordering avoids restarts when the provider only reorders its subscription.
| unique_by([.settings,.streamSettings])
| sort_by([.settings.vnext[0].address,.settings.vnext[0].port,.settings.vnext[0].users[0].id])
| if length < $count then error("Not enough supported, distinct Extra nodes") else .[:$count] end
| to_entries | map(.value + {tag:("blancvpn-node-" + (if .key+1<10 then "0" else "" end) + ((.key+1)|tostring) + "-end")})
BLANCVPN_EMBEDDED_FILE_3_END
cat > "$stage/lib/merge.jq" <<'BLANCVPN_EMBEDDED_FILE_4_END'
def owned: startswith("blancvpn-");
def broad:
  ((keys - ["type","ruleTag","inboundTag","outboundTag","balancerTag","network"])|length)==0
  and (((.network // "tcp,udp")|split(",")|sort) as $n | $n==["tcp","udp"] or $n==["tcp"] or $n==["udp"]);
def same_inbound: ((.inboundTag // [])|sort)==($c.inbound_tags|sort);
def vpn_rule: {type:"field",ruleTag:"blancvpn-default",inboundTag:$c.inbound_tags,network:"tcp,udp",balancerTag:"blancvpn-balancer"};
if $mode=="outbounds" then
  .outbounds = ((.outbounds // []) | map(select((.tag|owned)|not)))
  | if $c.fallback=="direct" and ([.outbounds[]|select(.tag=="direct" and .protocol=="freedom")]|length)!=1
    then error("Direct fallback needs an existing freedom outbound tagged direct in 04_outbounds.json") else . end
  | .outbounds += $nodes[0] + [{tag:"blancvpn-fallback-block",protocol:"blackhole",settings:{}}]
elif $mode=="routing" then
  .routing = (.routing // {})
  | .routing.balancers = ((.routing.balancers // [])|map(select((.tag|owned)|not)))
  | .routing.balancers += [{tag:"blancvpn-balancer",selector:($nodes[0]|map(.tag)),fallbackTag:(if $c.fallback=="direct" then "direct" else "blancvpn-fallback-block" end),
      strategy:(if $c.strategy=="leastLoad" then {type:"leastLoad",settings:{expected:2}} else {type:"leastPing"} end)}]
  | .routing.rules = ((.routing.rules // [])|map(select((.balancerTag // ""|owned)|not)))
  | if any(.routing.rules[]; broad and .inboundTag!=null and (same_inbound|not)
      and ([.inboundTag[]|select(. as $t|$c.inbound_tags|index($t)!=null)]|length)>0)
    then error("An overlapping default inbound rule needs manual review") else . end
  | .routing.rules |= map(select((broad and same_inbound)|not))
  | (reduce .routing.rules[] as $r ({rules:[],inserted:false};
      if (.inserted|not) and ($r|broad) and $r.inboundTag==null
      then .rules += [vpn_rule,$r] | .inserted=true else .rules += [$r] end))
    as $result
  | .routing.rules = (if $result.inserted then $result.rules else $result.rules+[vpn_rule] end)
elif $mode=="observer" then
  (((.observatory.subjectSelector // []) + (.burstObservatory.subjectSelector // []) | map(select(owned|not)))
    + ($nodes[0]|map(.tag)) | unique) as $subjects
  | if $c.strategy=="leastLoad" then
      .burstObservatory = ((.burstObservatory // {}) + {subjectSelector:$subjects,pingConfig:{destination:$c.probe_url,connectivity:"",interval:"1m",sampling:3,timeout:"5s",httpMethod:"HEAD"}})
      | del(.observatory)
    else
      .observatory = ((.observatory // {}) + {subjectSelector:$subjects,probeUrl:$c.probe_url,probeInterval:"1m",enableConcurrency:true})
      | del(.burstObservatory)
    end
else error("Unknown merge mode") end
BLANCVPN_EMBEDDED_FILE_4_END
cat > "$stage/lib/jsonc.awk" <<'BLANCVPN_EMBEDDED_FILE_5_END'
# Remove Xray-style comments only outside JSON strings. Preserve line numbers.
{
    out = ""
    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        nextc = substr($0, i + 1, 1)
        if (block) {
            if (c == "*" && nextc == "/") { block = 0; i++ }
            continue
        }
        if (quoted) {
            out = out c
            if (escaped) escaped = 0
            else if (c == "\\") escaped = 1
            else if (c == "\"") quoted = 0
            continue
        }
        if (c == "\"") { quoted = 1; out = out c }
        else if (c == "/" && nextc == "/") break
        else if (c == "/" && nextc == "*") { block = 1; i++; out = out " " }
        else out = out c
    }
    print out
    # JSON strings cannot contain a literal newline, even after a backslash.
    if (quoted) bad = 1
    escaped = 0
}
END {
    if (block || quoted || bad) {
        # Ensure downstream jq rejects the stream, even when an earlier object
        # was complete before an unterminated comment.
        print "[INVALID_JSON_COMMENT_OR_STRING"
        exit 1
    }
}
BLANCVPN_EMBEDDED_FILE_5_END
sh "$stage/install.sh"
