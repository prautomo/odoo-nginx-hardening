#!/usr/bin/env bash
# Send a scanner-style burst to YOUR OWN Odoo server and count the answers.
# Only run this against servers you are responsible for.
#
#   ./burst-test.sh https://odoo.example.com [requests=300] [parallel=150]
#
# Expected after hardening: some 404 (Odoo answered), many 429 (nginx
# limited), and no 500/502 (Odoo never ran out of database connections).
set -euo pipefail
URL=${1:?usage: $0 https://odoo.example.com [requests] [parallel]}
N=${2:-300}
P=${3:-150}

echo "Sending $N requests, $P in parallel, to random paths on $URL ..."
seq "$N" | xargs -P "$P" -I{} \
    curl -sk -o /dev/null --max-time 30 -w '%{http_code}\n' "$URL/burst-test-{}-$RANDOM" \
    | sort | uniq -c | awk '{printf "  HTTP %s: %s\n", $2, $1}'
echo "000 = connection closed or timed out."
