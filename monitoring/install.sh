#!/bin/bash
# Install odoo-alert with two systemd timers: a check every 5 minutes and a
# daily summary at 07:00 in ALERT_TZ. Run as root from this folder after
# creating /etc/odoo-alert.env.
set -euo pipefail
[ -f /etc/odoo-alert.env ] || { echo "create /etc/odoo-alert.env first"; exit 1; }
chmod 600 /etc/odoo-alert.env
. /etc/odoo-alert.env
install -m 755 odoo-alert.sh /usr/local/bin/odoo-alert

cat > /etc/systemd/system/odoo-alert.service <<'EOF'
[Unit]
Description=Odoo server checks with Telegram alerts
[Service]
Type=oneshot
ExecStart=/usr/local/bin/odoo-alert check
EOF
cat > /etc/systemd/system/odoo-alert.timer <<'EOF'
[Unit]
Description=Run Odoo server checks every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/odoo-alert-summary.service <<'EOF'
[Unit]
Description=Daily Odoo server summary to Telegram
[Service]
Type=oneshot
ExecStart=/usr/local/bin/odoo-alert summary
EOF
cat > /etc/systemd/system/odoo-alert-summary.timer <<EOF
[Unit]
Description=Daily Odoo server summary
[Timer]
OnCalendar=*-*-* 07:00:00 ${ALERT_TZ:-UTC}
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now odoo-alert.timer odoo-alert-summary.timer
/usr/local/bin/odoo-alert test
systemctl list-timers 'odoo-alert*' --no-pager
