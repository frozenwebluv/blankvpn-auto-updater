#!/bin/sh
set -u

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/opt/etc/xray/configs
GEN=/opt/sbin/generate_blanc_outbounds.sh
UPD=/opt/sbin/blanc-auto-update
OUT=/tmp/04_outbounds.json
ROUTING=/opt/etc/xray/configs/05_routing.json
OBS=/opt/etc/xray/configs/07_observatory.json
BACKUPS=/opt/etc/xray/backups
CRON_MINUTE=17

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[BlankVPN] $*"; }

install_mode() {
[ "$(id -u 2>/dev/null)" = "0" ] || die "Запустите скрипт от root."
[ -d "$CONF" ] || die "Не найден $CONF. Установите XKeen/Xray перед запуском."

for cmd in curl base64 awk jq xray xkeen crontab; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдено: $cmd"
done

SUB_URL="${1:-}"
if [ -z "$SUB_URL" ]; then
    printf "Вставьте URL подписки Blank VPN: "
    IFS= read -r SUB_URL
fi
[ -n "$SUB_URL" ] || die "URL подписки не указан."

printf "Период автообновления в часах [6]: "
IFS= read -r UPDATE_HOURS
UPDATE_HOURS="${UPDATE_HOURS:-6}"

case "$UPDATE_HOURS" in
    1|2|3|4|6|8|12|24) ;;
    *) die "Допустимый период: 1, 2, 3, 4, 6, 8, 12 или 24 часа." ;;
esac

CRON_LINE="$CRON_MINUTE */$UPDATE_HOURS * * * /opt/sbin/blanc-auto-update >> /opt/var/log/blanc-auto-update.log 2>&1"

mkdir -p "$BACKUPS" /opt/var/log || die "Не удалось создать каталоги."

ROUTING_EXISTED=0
OBS_EXISTED=0
[ -f "$ROUTING" ] && ROUTING_EXISTED=1
[ -f "$OBS" ] && OBS_EXISTED=1

cat > "$GEN" <<'GENEOF'
#!/bin/sh
set -u

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

SUB_URL='__BLANK_SUB_URL__'
OUT='/tmp/04_outbounds.json'
SUB='/tmp/blanc_subscription'
DECODED='/tmp/blanc_decoded'
NODES='/tmp/blanc_nodes'
TOTAL_FILE='/tmp/blanc_parser_total'
OLD='/tmp/blanc_old_outbounds.json'

curl -L -sS "$SUB_URL" -o "$SUB" || exit 1
base64 -d "$SUB" > "$DECODED" || exit 1

awk '
/^vless:\/\// {
    line=$0
    uuid=line
    sub(/^vless:\/\//, "", uuid)
    sub(/@.*/, "", uuid)

    split(line, label_parts, "#")
    label=label_parts[2]

    if (label !~ /Extra$/) next
    if (label ~ /Extra%20Whitelist/) next

    sub(/^vless:\/\/[^@]*@/, "", line)
    split(line, a, "?")
    server=a[1]
    params=a[2]
    split(server, b, ":")
    ip=b[1]
    port=b[2]
    sub(/#.*/, "", params)

    n=split(params, p, "&")
    sni=""
    pbk=""
    sid=""
    fp=""
    flow=""
    encryption=""

    for (i=1; i<=n; i++) {
        split(p[i], kv, "=")
        if (kv[1] == "sni") sni=kv[2]
        if (kv[1] == "pbk") pbk=kv[2]
        if (kv[1] == "sid") sid=kv[2]
        if (kv[1] == "fp") fp=kv[2]
        if (kv[1] == "flow") flow=kv[2]
        if (kv[1] == "encryption") encryption=kv[2]
    }

    if (uuid == "" || ip == "" || port == "" || sni == "" ||
        pbk == "" || sid == "" || fp == "" ||
        flow == "" || encryption == "") next

    count++

    if (count <= 6)
        printf "%02d|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
            count, uuid, ip, port, sni, pbk, sid, fp, flow, encryption
}
END {
    print "TOTAL=" count > "'"$TOTAL_FILE"'"
}
' "$DECODED" > "$NODES"

TOTAL=$(cat "$TOTAL_FILE" 2>/dev/null)
COUNT=${TOTAL#TOTAL=}

case "$COUNT" in
    ''|*[!0-9]*) echo "ERROR: не удалось определить количество серверов"; exit 1 ;;
esac

[ "$COUNT" -ge 6 ] || {
    echo "ERROR: доступно меньше 6 обычных Extra-серверов: $COUNT"
    exit 1
}

if [ -f /opt/etc/xray/configs/04_outbounds.json ]; then
    cp /opt/etc/xray/configs/04_outbounds.json "$OLD" || exit 1
else
    printf '%s\n' '{"outbounds":[]}' > "$OLD"
fi

jq '
  .outbounds = (
    [{"tag":"direct","protocol":"freedom"}]
    + [
        (.outbounds // [])[]
        | select(
            .tag != "direct"
            and ((.tag | test("^blanc-[0-9]{2}$")) | not)
          )
      ]
  )
' "$OLD" > /tmp/blanc_preserved.json || exit 1

jq -e '.outbounds | type == "array"' /tmp/blanc_preserved.json >/dev/null || exit 1

jq '{
  outbounds: [
    (.outbounds[] | select(.tag == "direct")),
    .outbounds[] | select(.tag != "direct")
  ]
}' /tmp/blanc_preserved.json > /tmp/blanc_base.json || exit 1

cp /tmp/blanc_base.json "$OUT"

i=1
while IFS='|' read -r num uuid ip port sni pbk sid fp flow encryption
do
    [ -n "$num" ] || continue
    jq --arg tag "blanc-$(printf '%02d' "$i")" \
       --arg uuid "$uuid" \
       --arg ip "$ip" \
       --argjson port "$port" \
       --arg sni "$sni" \
       --arg pbk "$pbk" \
       --arg sid "$sid" \
       --arg fp "$fp" \
       --arg flow "$flow" \
       --arg encryption "$encryption" '
       .outbounds += [{
         tag: $tag,
         protocol: "vless",
         settings: {
           vnext: [{
             address: $ip,
             port: $port,
             users: [{
               id: $uuid,
               encryption: $encryption,
               flow: $flow
             }]
           }]
         },
         streamSettings: {
           network: "tcp",
           security: "reality",
           realitySettings: {
             serverName: $sni,
             fingerprint: $fp,
             publicKey: $pbk,
             shortId: $sid
           }
         }
       }]
       ' "$OUT" > "$OUT.tmp" || exit 1
    mv "$OUT.tmp" "$OUT"
    i=$((i + 1))
done < "$NODES"

jq empty "$OUT" || exit 1

jq -e '
  (.outbounds | type == "array")
  and ([.outbounds[] | select(.tag == "blanc-01")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-02")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-03")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-04")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-05")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-06")] | length == 1)
  and ([.outbounds[] | select(.tag == "direct")] | length == 1)
  and ([.outbounds[] | select(.tag | test("^blanc-[0-9]{2}$")) | .protocol] | all(. == "vless"))
' "$OUT" >/dev/null || exit 1

if grep -Eiq 'Whitelist|eh[0-9]*\.vk\.ru|eh\.vk\.ru' "$OUT"; then
    echo "ERROR: whitelist node detected"
    exit 1
fi

if grep -q 'spiderX' "$OUT"; then
    echo "ERROR: spiderX detected"
    exit 1
fi

echo "Generated: $OUT"
echo "Normal Extra servers in subscription: $COUNT"
echo "BlankVPN outbounds: 6"
GENEOF

awk -v url="$SUB_URL" '{ gsub(/__BLANK_SUB_URL__/, url); print }' "$GEN" > "$GEN.tmp" || die "Не удалось записать URL подписки."
mv "$GEN.tmp" "$GEN"
chmod 700 "$GEN"

cat > "$UPD" <<'UPDEOF'
#!/bin/sh
set -u

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

GEN=/opt/sbin/generate_blanc_outbounds.sh
TARGET=/opt/etc/xray/configs/04_outbounds.json
CANDIDATE=/tmp/04_outbounds.blanc.candidate.json
STAGE=/tmp/xray-blanc-stage.$$
BACKUPS=/opt/etc/xray/backups
LOCK=/tmp/blanc-auto-update.lock

log() {
    logger -t blanc-auto-update "$*" 2>/dev/null || echo "$*"
}

cleanup() {
    rm -rf "$STAGE"
    rm -f "$CANDIDATE"
    rmdir "$LOCK" 2>/dev/null
}

trap cleanup EXIT INT TERM

if ! mkdir "$LOCK" 2>/dev/null; then
    log "another update is already running; skipping"
    exit 0
fi

mkdir -p "$BACKUPS" || exit 1
rm -f /tmp/04_outbounds.json "$CANDIDATE"

if ! "$GEN"; then
    log "generation failed; active configuration was kept"
    exit 1
fi

cp /tmp/04_outbounds.json "$CANDIDATE" || exit 1

jq -e '
  (.outbounds | type == "array")
  and ([.outbounds[] | select(.tag == "blanc-01")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-02")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-03")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-04")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-05")] | length == 1)
  and ([.outbounds[] | select(.tag == "blanc-06")] | length == 1)
  and ([.outbounds[] | select(.tag == "direct")] | length == 1)
' "$CANDIDATE" >/dev/null || {
    log "candidate JSON failed safety checks"
    exit 1
}

if grep -Eiq 'Whitelist|eh[0-9]*\.vk\.ru|eh\.vk\.ru' "$CANDIDATE"; then
    log "whitelist detected; active configuration was kept"
    exit 1
fi

if grep -q 'spiderX' "$CANDIDATE"; then
    log "spiderX detected; active configuration was kept"
    exit 1
fi

mkdir -p "$STAGE" || exit 1
cp /opt/etc/xray/configs/*.json "$STAGE/" || exit 1
cp "$CANDIDATE" "$STAGE/04_outbounds.json" || exit 1

if ! xray run -test -confdir "$STAGE" >/dev/null 2>&1; then
    log "Xray rejected staged configuration; active configuration was kept"
    exit 1
fi

if cmp -s "$CANDIDATE" "$TARGET"; then
    log "subscription result unchanged; no restart needed"
    exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUPS/04_outbounds.json.$stamp"

cp "$TARGET" "$backup" || exit 1
cp "$CANDIDATE" "$TARGET.new" || exit 1
mv "$TARGET.new" "$TARGET" || exit 1

if xkeen -restart >/dev/null 2>&1 &&
   xkeen -status 2>&1 | grep -q 'запущен'; then
    log "updated successfully; backup: $backup"
    exit 0
fi

log "restart failed; restoring previous configuration"
cp "$backup" "$TARGET"
xkeen -restart >/dev/null 2>&1 ||
    log "rollback restart also failed; manual attention required"

exit 1
UPDEOF

chmod 700 "$UPD"

stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUPS"

[ -f "$CONF/04_outbounds.json" ] && cp "$CONF/04_outbounds.json" "$BACKUPS/04_outbounds.json.installer.$stamp"
[ -f "$ROUTING" ] && cp "$ROUTING" "$BACKUPS/05_routing.json.installer.$stamp"
[ -f "$OBS" ] && cp "$OBS" "$BACKUPS/07_observatory.json.installer.$stamp"

"$GEN" || die "Не удалось получить серверы BlankVPN."

jq -e '
  .routing = (.routing // {})
  | .routing.rules = (.routing.rules // [])
  | .routing.balancers = (.routing.balancers // [])
  | .routing.balancers = [
      .routing.balancers[] | select(.tag != "blanc-balancer")
    ]
  | .routing.balancers += [{
      tag: "blanc-balancer",
      selector: ["blanc-01","blanc-02","blanc-03","blanc-04","blanc-05","blanc-06"],
      strategy: {type:"leastPing"},
      fallbackTag: "direct"
    }]
  | .routing.rules = [
      .routing.rules[]
      | select(
          (.balancerTag != "blanc-balancer")
          and
          (
            (.balancerTag == null)
            or
            ((.inboundTag // []) != ["redirect","tproxy"])
          )
        )
    ]
  | .routing.rules = (
      .routing.rules as $r
      | ($r | map(
          if (
            (.domain == null)
            and (.ip == null)
            and (.port == null)
            and (.protocol == null)
            and (.source == null)
            and (.user == null)
            and (.inboundTag == null)
            and (.attrs == null)
          ) then . else empty end
        ) | length) as $dummy
      | if (
          ($r | map(
            select(
              (.domain == null)
              and (.ip == null)
              and (.port == null)
              and (.protocol == null)
              and (.source == null)
              and (.user == null)
              and (.inboundTag == null)
              and (.attrs == null)
            )
          ) | length) > 0
        )
        then
          reduce $r[] as $rule (
            {done:false, rules:[]};
            if (
              (.done == false)
              and ($rule.domain == null)
              and ($rule.ip == null)
              and ($rule.port == null)
              and ($rule.protocol == null)
              and ($rule.source == null)
              and ($rule.user == null)
              and ($rule.inboundTag == null)
              and ($rule.attrs == null)
            )
            then {
              done:true,
              rules: (.rules + [{
                inboundTag:["redirect","tproxy"],
                balancerTag:"blanc-balancer",
                network:"tcp,udp"
              }, $rule])
            }
            else .rules += [$rule]
            end
          ).rules
        else
          ($r + [{
            inboundTag:["redirect","tproxy"],
            balancerTag:"blanc-balancer",
            network:"tcp,udp"
          }])
        end
    )
' "$ROUTING" > "$ROUTING.new" 2>/dev/null || {
    if [ -f "$ROUTING" ]; then
        cp "$ROUTING" "$ROUTING.new"
    else
        printf '%s\n' '{"routing":{"domainStrategy":"AsIs","rules":[{"inboundTag":["redirect","tproxy"],"balancerTag":"blanc-balancer","network":"tcp,udp"}],"balancers":[{"tag":"blanc-balancer","selector":["blanc-01","blanc-02","blanc-03","blanc-04","blanc-05","blanc-06"],"strategy":{"type":"leastPing"},"fallbackTag":"direct"}]}}' > "$ROUTING.new"
    fi
}

jq empty "$ROUTING.new" || die "Не удалось подготовить 05_routing.json."
mv "$ROUTING.new" "$ROUTING"

if [ -f "$OBS" ]; then
    jq '
      .observatory = (.observatory // {})
      | .observatory.subjectSelector = (
          ((.observatory.subjectSelector // []) +
          ["blanc-01","blanc-02","blanc-03","blanc-04","blanc-05","blanc-06"])
          | unique
        )
      | .observatory.probeUrl = (.observatory.probeUrl // "https://www.gstatic.com/generate_204")
      | .observatory.probeInterval = (.observatory.probeInterval // "1m")
      | .observatory.enableConcurrency = (.observatory.enableConcurrency // true)
    ' "$OBS" > "$OBS.new" || die "Не удалось подготовить 07_observatory.json."
else
    printf '%s\n' '{"observatory":{"subjectSelector":["blanc-01","blanc-02","blanc-03","blanc-04","blanc-05","blanc-06"],"probeUrl":"https://www.gstatic.com/generate_204","probeInterval":"1m","enableConcurrency":true}}' > "$OBS.new"
fi

jq empty "$OBS.new" || die "Не удалось проверить 07_observatory.json."
mv "$OBS.new" "$OBS"

cp "$OUT" "$CONF/04_outbounds.json.new" || die "Не удалось подготовить 04_outbounds.json."
mv "$CONF/04_outbounds.json.new" "$CONF/04_outbounds.json"

STAGE="/tmp/xray-blanc-install.$$.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE" || die "Не удалось создать stage."
cp "$CONF"/*.json "$STAGE/" || die "Не удалось собрать конфигурацию Xray."

if ! xray run -test -confdir "$STAGE" >/dev/null 2>&1; then
    rm -rf "$STAGE"
    [ -f "$BACKUPS/04_outbounds.json.installer.$stamp" ] && cp "$BACKUPS/04_outbounds.json.installer.$stamp" "$CONF/04_outbounds.json"
    if [ "$ROUTING_EXISTED" = "1" ]; then
        [ -f "$BACKUPS/05_routing.json.installer.$stamp" ] && cp "$BACKUPS/05_routing.json.installer.$stamp" "$ROUTING"
    else
        rm -f "$ROUTING"
    fi
    if [ "$OBS_EXISTED" = "1" ]; then
        [ -f "$BACKUPS/07_observatory.json.installer.$stamp" ] && cp "$BACKUPS/07_observatory.json.installer.$stamp" "$OBS"
    else
        rm -f "$OBS"
    fi
    die "Xray отверг конфигурацию. Изменения отменены."
fi

rm -rf "$STAGE"

xkeen -restart >/dev/null 2>&1 || {
    [ -f "$BACKUPS/04_outbounds.json.installer.$stamp" ] && cp "$BACKUPS/04_outbounds.json.installer.$stamp" "$CONF/04_outbounds.json"
    if [ "$ROUTING_EXISTED" = "1" ]; then
        [ -f "$BACKUPS/05_routing.json.installer.$stamp" ] && cp "$BACKUPS/05_routing.json.installer.$stamp" "$ROUTING"
    else
        rm -f "$ROUTING"
    fi
    if [ "$OBS_EXISTED" = "1" ]; then
        [ -f "$BACKUPS/07_observatory.json.installer.$stamp" ] && cp "$BACKUPS/07_observatory.json.installer.$stamp" "$OBS"
    else
        rm -f "$OBS"
    fi
    xkeen -restart >/dev/null 2>&1
    die "Не удалось запустить XKeen. Предыдущая конфигурация восстановлена."
}

xkeen -status 2>&1 | grep -q 'запущен' || die "Xray не подтверждён как запущенный."

TMP_CRON="/tmp/blanc-crontab.$$"
crontab -l 2>/dev/null | grep -v '/opt/sbin/blanc-auto-update' > "$TMP_CRON" || true
echo "$CRON_LINE" >> "$TMP_CRON"
crontab "$TMP_CRON" || die "Не удалось установить cron."
rm -f "$TMP_CRON"

info "Готово."
echo
echo "BlankVPN установлен."
echo "Балансировка: blanc-balancer / leastPing"
echo "Observatory: blanc-01..blanc-06"
echo "Автообновление: каждые $UPDATE_HOURS часов"
echo "Backups: $BACKUPS"
echo
echo "xkeen -status"

}

uninstall_mode() {
    [ "$(id -u 2>/dev/null)" = "0" ] || die "Запустите скрипт от root."

    GEN=/opt/sbin/generate_blanc_outbounds.sh
    UPD=/opt/sbin/blanc-auto-update
    BACKUPS=/opt/etc/xray/backups
    CONF=/opt/etc/xray/configs
    ROUTING="$CONF/05_routing.json"
    OBS="$CONF/07_observatory.json"
    TARGET="$CONF/04_outbounds.json"

    crontab -l 2>/dev/null | grep -v '/opt/sbin/blanc-auto-update' | crontab - 2>/dev/null || true

    rm -f "$GEN" "$UPD"

    latest_backup() {
        ls -1t "$BACKUPS/$1" 2>/dev/null | head -n 1
    }

    b=$(latest_backup '04_outbounds.json.installer.*')
    if [ -n "$b" ] && [ -f "$BACKUPS/$b" ]; then
        cp "$BACKUPS/$b" "$TARGET"
    else
        jq 'del(.outbounds[] | select(.tag | test("^blanc-[0-9]{2}$")))' "$TARGET" > "$TARGET.new" 2>/dev/null &&
        mv "$TARGET.new" "$TARGET"
    fi

    b=$(latest_backup '05_routing.json.installer.*')
    if [ -n "$b" ] && [ -f "$BACKUPS/$b" ]; then
        cp "$BACKUPS/$b" "$ROUTING"
    elif [ -f "$ROUTING" ]; then
        jq '
          .routing.rules = [
            (.routing.rules // [])[]
            | select(
                (.balancerTag != "blanc-balancer")
                and (
                    ((.outboundTag // "") != "blanc-balancer")
                )
              )
          ]
          | .routing.balancers = [
              (.routing.balancers // [])[]
              | select(.tag != "blanc-balancer")
            ]
        ' "$ROUTING" > "$ROUTING.new" 2>/dev/null &&
        mv "$ROUTING.new" "$ROUTING"
    fi

    b=$(latest_backup '07_observatory.json.installer.*')
    if [ -n "$b" ] && [ -f "$BACKUPS/$b" ]; then
        cp "$BACKUPS/$b" "$OBS"
    else
        rm -f "$OBS"
    fi

    xray run -test -confdir "$CONF" >/dev/null 2>&1 || {
        echo "Не удалось проверить конфигурацию после удаления."
        exit 1
    }

    xkeen -restart >/dev/null 2>&1 || {
        echo "Не удалось перезапустить XKeen."
        exit 1
    }

    echo "BlankVPN Auto Updater удалён."
    echo "Предыдущая конфигурация восстановлена, если был найден backup."
}

printf "BlankVPN Auto Updater\n"
printf "1) Установить\n"
printf "2) Удалить\n"
printf "Выберите действие [1]: "
IFS= read -r ACTION
ACTION="${ACTION:-1}"

case "$ACTION" in
    1) install_mode ;;
    2) uninstall_mode ;;
    *) die "Введите 1 или 2." ;;
esac
