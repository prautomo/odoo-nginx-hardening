# odoo-nginx-hardening

nginx, Odoo, and fail2ban settings that stop internet scanners from exhausting
Odoo's database connection pool, plus a small Telegram alert script.

[Bahasa Indonesia](README.id.md) · [Need help setting it up?](#need-help-setting-it-up)

## The problem

Odoo runs with `workers = 0` by default. One process serves every request, and
all requests share one PostgreSQL pool of `db_maxconn` connections (64 by
default). Even a request for a page that does not exist uses a connection,
because the website module renders its 404 page from the database.

A vulnerability scanner does not wait for answers. It fires a list of paths
(`/.env`, `/wp-config.php~`, random strings) in parallel. When more than 64 of
them reach Odoo at once, every request after that fails with:

```
psycopg2.pool.PoolError: The Connection Pool Is Full
```

For about a minute, real users get errors too.

## What happened to us

We moved a client's Odoo 12 to a new server. To cover users whose DNS still
pointed at the old address, the old server kept a temporary nginx reverse proxy
to the new one. That proxy was the only HTTPS site on the old server, so it
answered every request to the old IP and forwarded it with the correct
`Host` header. The new server rejects requests for unknown hostnames, but these
arrived looking legitimate.

Within three days a scanner (93.152.209.6, claiming to be Googlebot) hit the old
IP three times, about 480 requests per minute each time. The proxy forwarded
around 150 of them at once and the pool ran out each time. The first two runs
fell on a weekend. The third, on a Monday evening, made one request from a real
user fail. By then DNS had pointed at the new server for more than two days and
only bots were using the proxy, so we shut it down. This repository collects
the hardening that came out of it.

Lesson for migrations: a temporary forwarding proxy should only answer the
hostnames it needs, carry the same limits as the real server, and be removed as
soon as DNS caches have expired.

## The layers

| Layer | File | What it does |
|---|---|---|
| Reject unknown hosts | `nginx/sites/00-default-reject.conf` | Requests to the raw IP or an unknown name get no response and no TLS certificate. |
| Drop scanner junk | `nginx/sites/odoo.example.com.conf` | `/.env`, `/.git`, `*.php`, `wp-*` and similar are closed by nginx before they reach Odoo. |
| Limit per IP | `nginx/conf.d/odoo-limits.conf` | At most 40 concurrent connections and 20 requests per second per IP (burst 200), 10 login POSTs per minute. 40 stays well below the 64-connection pool. |
| Ban repeat offenders | `fail2ban/` | Bans IPs that keep hitting the limits. Ships its own filter, because the stock `nginx-limit-req` filter ignores `limit_conn`. |
| Multi-process Odoo | `odoo/odoo.conf.example` | `workers > 0` gives each worker its own small pool, so one burst cannot take all of them. Includes the connection budget formula. |
| Alerts | `monitoring/` | Telegram message when the pool runs out, disk, memory or load cross a limit, a container stops, a backup fails, or a cryptominer process appears. |

## Install

On an Ubuntu server with nginx in front of Odoo:

```bash
sudo cp nginx/conf.d/odoo-limits.conf      /etc/nginx/conf.d/
sudo cp nginx/snippets/odoo-proxy.conf     /etc/nginx/snippets/
sudo cp nginx/sites/00-default-reject.conf /etc/nginx/sites-enabled/
sudo cp nginx/sites/odoo.example.com.conf  /etc/nginx/sites-enabled/odoo.conf
# edit odoo.conf: hostname, certificate paths, /longpolling or /websocket
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

sudo cp fail2ban/filter.d/odoo-nginx-limit.conf /etc/fail2ban/filter.d/
sudo cp fail2ban/jail.d/odoo-nginx.local        /etc/fail2ban/jail.d/
sudo systemctl restart fail2ban
```

If many users share one office IP, add it to the `geo` block in
`odoo-limits.conf` and to `ignoreip` in the jail. Otherwise a busy morning can
look like a burst.

Switching Odoo to workers needs a restart and the gevent port (8072) published
to nginx. Read the comments in `odoo/odoo.conf.example` first.

Alerts: see `monitoring/odoo-alert.env.example`, then run
`sudo ./monitoring/install.sh`.

## Verify

```bash
./tools/burst-test.sh https://your-odoo.example.com 300 150
```

Run it only against servers you are responsible for. Expect a mix of 404 and
429, and no 500 or 502.

## Test results

We tested the nginx files with nginx 1.24 and 1.27 in front of a fake Odoo that
takes one second per request and records how many requests it handles at once.

| Test | Result |
|---|---|
| `nginx -t` on 1.24 and 1.27 | OK |
| HTTPS to the raw IP | TLS handshake rejected |
| `/.env`, `/.git/config`, `/wp-login.php`, `/x.php` | Connection closed by nginx, nothing reached Odoo |
| `/web/database/manager` | 404 from nginx |
| 300 requests, 150 in parallel | 80 reached Odoo, 220 got 429. Peak at Odoo: **40 at once** |
| Same burst from an exempt IP | 300 reached Odoo. Peak: **150 at once** |
| 15 login POSTs in a row | 13 passed, then 429 |
| `fail2ban-regex` on the 222 resulting log lines | 222 matched, 0 missed |

The exempt-IP row shows what the limits prevent: without them, the burst lands
on Odoo all at once.

## Compatibility

Written for Odoo 12 to 15 (`/longpolling`). Odoo 16 and later use
`/websocket` and `gevent_port`; both are in the files as comments. nginx 1.19.4
or newer is required for `ssl_reject_handshake`.

## Need help setting it up?

Karisma Technologies installs this on production Odoo servers: tuning the
limits for your office network, switching Odoo to workers, Telegram alerts,
encrypted off-site backups, and regular server status reports. Contact us at
[info@karismatech.com](mailto:info@karismatech.com) or visit
[karismatech.com](https://karismatech.com).

## License

MIT. Made by [Karisma Technologies](https://karismatech.com).
