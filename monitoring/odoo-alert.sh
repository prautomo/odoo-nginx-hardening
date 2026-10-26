#!/bin/bash
# Telegram alerts for an Odoo server. Run by systemd every 5 minutes
# ("check") and once a day ("summary"). A message is sent only when a
# condition changes: once when a problem starts, once when it recovers.
# Settings and the bot token live in /etc/odoo-alert.env (see odoo-alert.env.example).
set -u
MODE=${1:-check}
. /etc/odoo-alert.env
export TZ=${ALERT_TZ:-UTC}
STATE=/var/lib/odoo-alert
mkdir -p "$STATE"
HOST=${HOST_LABEL:-$(hostname)}

send() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT" -d disable_web_page_preview=true \
        --data-urlencode text="$1" | grep -q '^200$'
}

# check KEY BAD MESSAGE [FAILURES_BEFORE_ALERT]
check() {
    local key=$1 bad=$2 msg=$3 need=${4:-1} cnt=0
    [ -f "$STATE/$key.cnt" ] && cnt=$(cat "$STATE/$key.cnt")
    if [ "$bad" = 1 ]; then
        cnt=$((cnt + 1)); echo "$cnt" > "$STATE/$key.cnt"
        if [ "$cnt" -ge "$need" ] && [ ! -f "$STATE/$key.sent" ]; then
            send "🔴 ${HOST}: ${msg}" && echo "$msg" > "$STATE/$key.sent"
        fi
    else
        rm -f "$STATE/$key.cnt"
        if [ -f "$STATE/$key.sent" ]; then
            send "✅ ${HOST} recovered: $(cat "$STATE/$key.sent")" && rm -f "$STATE/$key.sent"
        fi
    fi
}

disk_pct=$(df --output=pcent / | tail -1 | tr -dc 0-9)
mem_avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swap_used=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
read -r l1 l5 l15 _ < /proc/loadavg
cpus=$(nproc)

cert_days() {
    local end
    end=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$CERT_NAME" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] && echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 )) || echo -1
}

odoo_logs() {  # $1 = how far back, e.g. 5m or 24h
    if [ -n "${ODOO_COMPOSE:-}" ]; then
        docker compose -f "$ODOO_COMPOSE" logs --no-log-prefix --since "$1" "${ODOO_SERVICE:-odoo}" 2>/dev/null
    elif [ -n "${ODOO_UNIT:-}" ]; then
        journalctl -u "$ODOO_UNIT" --since "-$1" -o cat 2>/dev/null
    fi
}

if [ "$MODE" = check ]; then
    check disk "$([ "$disk_pct" -gt "$DISK_MAX" ] && echo 1 || echo 0)" "disk / at ${disk_pct}% (limit ${DISK_MAX}%)"
    check mem "$([ "$mem_avail" -lt "$MEM_MIN_MB" ] && echo 1 || echo 0)" "only ${mem_avail} MiB memory available (limit ${MEM_MIN_MB} MiB)" 2
    check swap "$([ "$swap_used" -gt "$SWAP_MAX_MB" ] && echo 1 || echo 0)" "${swap_used} MiB swap in use (limit ${SWAP_MAX_MB} MiB)" 2
    check load "$(awk -v a="$l15" -v b="$LOAD_MAX" 'BEGIN{print (a>b)?1:0}')" "high CPU load: 15-min average ${l15} on ${cpus} cores (limit ${LOAD_MAX})"

    # Known cryptominer names. A hit here means the server is compromised.
    miner=$(pgrep -fa '[x]mrig|[m]inerd|[k]devtmpfsi|[k]insing|stratum\+tcp' | grep -v odoo-alert | head -3)
    check miner "$([ -n "$miner" ] && echo 1 || echo 0)" "SUSPICIOUS PROCESS (cryptominer?): ${miner:0:200}"

    for c in ${CONTAINERS:-}; do
        st=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$c" 2>/dev/null || echo "missing 0")
        check "ctr-$c" "$([ "${st%% *}" = running ] && echo 0 || echo 1)" "container ${c} is not running (${st%% *})"
        rc=${st##* }; old=$(cat "$STATE/ctr-$c.rc" 2>/dev/null || echo "$rc")
        [ "$rc" -gt "$old" ] && send "🟠 ${HOST}: container ${c} restarted by itself (${rc} times in total)"
        echo "$rc" > "$STATE/ctr-$c.rc"
    done

    # Watch another server from the outside, so a dead server is still noticed.
    if [ -n "${PEER_URL:-}" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PEER_URL")
        check peer "$([ "$code" = 200 ] && echo 0 || echo 1)" "${PEER_NAME} unreachable from ${HOST} (${PEER_URL} -> ${code})" 2
    fi

    if [ -n "${CERT_NAME:-}" ]; then
        d=$(cert_days)
        check cert "$([ "$d" -ge 0 ] && [ "$d" -lt 14 ] && echo 1 || echo 0)" "HTTPS certificate for ${CERT_NAME} expires in ${d} days"
    fi

    if [ -n "${ODOO_COMPOSE:-}${ODOO_UNIT:-}" ]; then
        logs=$(odoo_logs 5m)
        pool=$(grep -c 'Connection Pool Is Full' <<<"$logs")
        crit=$(grep -c ' CRITICAL ' <<<"$logs")
        err=$(grep -c ' ERROR ' <<<"$logs")
        check odoo-pool "$([ "$pool" -gt 0 ] && echo 1 || echo 0)" "Odoo ran out of database connections (${pool} times in 5 min)"
        check odoo-crit "$([ "$crit" -gt 0 ] && echo 1 || echo 0)" "Odoo logged ${crit} CRITICAL errors in 5 min"
        check odoo-err "$([ "$err" -gt "${ODOO_ERR_MAX:-20}" ] && echo 1 || echo 0)" "Odoo logged ${err} errors in 5 min (limit ${ODOO_ERR_MAX:-20})"
    fi

    # Optional: backup jobs that write a status file such as
    # "OK 2026-10-26_0200 :: details" or "FAIL ...".
    # BACKUP_CHECKS="name:file:hour_by_which_today_must_appear ..."
    if [ -n "${BACKUP_CHECKS:-}" ]; then
        today=$(date +%F); h=$((10#$(date +%H)))
        for b in $BACKUP_CHECKS; do
            IFS=: read -r name file after <<<"$b"
            line=$(cat "$file" 2>/dev/null || echo "MISSING $file")
            bad=0
            case "$line" in OK*) ;; *) bad=1 ;; esac
            [ "$h" -ge "$after" ] && [[ "$line" != *"$today"* ]] && bad=1
            check "backup-$name" "$bad" "backup ${name} failed or did not run: ${line:0:160}"
        done
    fi

elif [ "$MODE" = summary ]; then
    msg="☀️ ${HOST} · $(date '+%d %b %Y %H:%M %Z')
Load: ${l1} / ${l5} / ${l15} (${cpus} cores)
Memory available: ${mem_avail} MiB · swap used: ${swap_used} MiB
Disk /: ${disk_pct}%"
    [ -n "${CERT_NAME:-}" ] && msg="${msg}
Certificate ${CERT_NAME}: $(cert_days) days left"
    for b in ${BACKUP_CHECKS:-}; do
        IFS=: read -r name file _ <<<"$b"
        msg="${msg}
Backup ${name}: $(cut -c1-100 "$file" 2>/dev/null || echo missing)"
    done
    if [ -n "${ODOO_COMPOSE:-}${ODOO_UNIT:-}" ]; then
        msg="${msg}
Odoo errors in 24 h: $(odoo_logs 24h | grep -c ' ERROR ')"
    fi
    f2b=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/{gsub(/ /,"",$2); print $2}')
    [ -n "$f2b" ] && msg="${msg}
fail2ban sshd bans (total): ${f2b}"
    open=$(ls "$STATE"/*.sent 2>/dev/null | wc -l)
    [ "$open" -gt 0 ] && msg="${msg}
Open problems: ${open}"
    send "$msg"

elif [ "$MODE" = test ]; then
    send "🧪 ${HOST}: test alert, Telegram delivery works ($(date '+%d %b %Y %H:%M %Z'))" && echo sent
fi
