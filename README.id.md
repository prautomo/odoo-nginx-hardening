# odoo-nginx-hardening

Pengaturan nginx, Odoo, dan fail2ban supaya pemindai internet tidak bisa
menghabiskan koneksi database Odoo, ditambah skrip peringatan Telegram.

[English](README.md) · [Butuh bantuan memasangnya?](#butuh-bantuan-memasangnya)

## Masalahnya

Secara bawaan Odoo berjalan dengan `workers = 0`. Satu proses melayani semua
request, dan semua request berbagi satu pool koneksi PostgreSQL berisi
`db_maxconn` koneksi (bawaannya 64). Request ke halaman yang tidak ada pun tetap
memakai koneksi, karena modul website mengambil halaman 404 dari database.

Pemindai celah keamanan tidak menunggu jawaban. Ia mengirim daftar path
(`/.env`, `/wp-config.php~`, string acak) secara paralel. Begitu lebih dari 64
sampai ke Odoo bersamaan, request berikutnya gagal dengan:

```
psycopg2.pool.PoolError: The Connection Pool Is Full
```

Selama sekitar satu menit, pengguna asli ikut mendapat error.

## Yang kami alami

Kami memindahkan Odoo 12 milik klien ke server baru. Untuk pengguna yang DNS-nya
masih menunjuk ke alamat lama, server lama dipasangi reverse proxy nginx
sementara ke server baru. Proxy itu satu-satunya situs HTTPS di server lama,
jadi semua request ke IP lama dijawabnya dan diteruskan dengan header `Host`
yang benar. Server baru menolak request untuk nama host yang tidak dikenal, tapi
request dari proxy ini datang dengan tampilan sah.

Dalam tiga hari, sebuah pemindai (93.152.209.6, mengaku sebagai Googlebot)
menembak IP lama tiga kali, masing-masing sekitar 480 request per menit. Proxy
meneruskan sekitar 150 request sekaligus dan pool habis setiap kali. Dua
kejadian pertama jatuh di akhir pekan. Yang ketiga, Senin malam, membuat satu
request pengguna asli gagal. Saat itu DNS sudah lebih dari dua hari menunjuk ke
server baru dan proxy hanya dipakai bot, jadi proxy kami matikan. Repo ini
berisi pengamanan yang kami susun dari kejadian itu.

Pelajaran untuk migrasi: proxy penerus sementara sebaiknya hanya menjawab nama
host yang diperlukan, punya batas yang sama dengan server aslinya, dan dicabut
begitu cache DNS habis.

## Lapisan pengamanan

| Lapisan | File | Fungsinya |
|---|---|---|
| Tolak host tak dikenal | `nginx/sites/00-default-reject.conf` | Request ke IP mentah atau nama asing tidak dijawab, sertifikat TLS pun tidak diberikan. |
| Buang sampah pemindai | `nginx/sites/odoo.example.com.conf` | `/.env`, `/.git`, `*.php`, `wp-*` dan sejenisnya diputus nginx sebelum sampai ke Odoo. |
| Batas per IP | `nginx/conf.d/odoo-limits.conf` | Maksimal 40 koneksi bersamaan dan 20 request per detik per IP (burst 200), 10 POST login per menit. Angka 40 jauh di bawah pool 64. |
| Blokir pelanggar berulang | `fail2ban/` | Memblokir IP yang terus kena batas. Filternya dibuat sendiri, karena filter bawaan `nginx-limit-req` tidak mengenali `limit_conn`. |
| Odoo multi-proses | `odoo/odoo.conf.example` | Dengan `workers > 0`, tiap worker punya pool kecil sendiri, jadi satu lonjakan tidak bisa menghabiskan semuanya. Ada rumus anggaran koneksinya. |
| Peringatan | `monitoring/` | Pesan Telegram saat pool habis, disk, memori, atau beban melewati batas, container berhenti, backup gagal, atau ada proses penambang kripto. |

## Pemasangan

Di server Ubuntu dengan nginx di depan Odoo:

```bash
sudo cp nginx/conf.d/odoo-limits.conf      /etc/nginx/conf.d/
sudo cp nginx/snippets/odoo-proxy.conf     /etc/nginx/snippets/
sudo cp nginx/sites/00-default-reject.conf /etc/nginx/sites-enabled/
sudo cp nginx/sites/odoo.example.com.conf  /etc/nginx/sites-enabled/odoo.conf
# sunting odoo.conf: nama host, lokasi sertifikat, /longpolling atau /websocket
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

sudo cp fail2ban/filter.d/odoo-nginx-limit.conf /etc/fail2ban/filter.d/
sudo cp fail2ban/jail.d/odoo-nginx.local        /etc/fail2ban/jail.d/
sudo systemctl restart fail2ban
```

Kalau banyak pengguna berbagi satu IP kantor, masukkan IP itu ke blok `geo` di
`odoo-limits.conf` dan ke `ignoreip` di jail. Kalau tidak, pagi yang sibuk bisa
terbaca sebagai lonjakan.

Mengubah Odoo ke mode workers butuh restart dan port gevent (8072) yang
diteruskan dari nginx. Baca dulu komentar di `odoo/odoo.conf.example`.

Peringatan: lihat `monitoring/odoo-alert.env.example`, lalu jalankan
`sudo ./monitoring/install.sh`.

## Cara memeriksa

```bash
./tools/burst-test.sh https://odoo-anda.example.com 300 150
```

Jalankan hanya ke server yang menjadi tanggung jawab Anda. Hasil yang
diharapkan: campuran 404 dan 429, tanpa 500 atau 502.

## Hasil uji

File nginx kami uji dengan nginx 1.24 dan 1.27 di depan Odoo tiruan yang butuh
satu detik per request dan mencatat berapa request yang ditanganinya sekaligus.

| Uji | Hasil |
|---|---|
| `nginx -t` di 1.24 dan 1.27 | OK |
| HTTPS ke IP mentah | Jabat tangan TLS ditolak |
| `/.env`, `/.git/config`, `/wp-login.php`, `/x.php` | Koneksi diputus nginx, tidak ada yang sampai ke Odoo |
| `/web/database/manager` | 404 dari nginx |
| 300 request, 150 paralel | 80 sampai ke Odoo, 220 mendapat 429. Puncak di Odoo: **40 sekaligus** |
| Lonjakan yang sama dari IP yang dikecualikan | 300 sampai ke Odoo. Puncak: **150 sekaligus** |
| 15 POST login berturut-turut | 13 lolos, lalu 429 |
| `fail2ban-regex` pada 222 baris log hasil uji | 222 cocok, 0 terlewat |

Baris IP yang dikecualikan menunjukkan apa yang dicegah oleh batas ini: tanpa
batas, seluruh lonjakan sampai ke Odoo bersamaan.

## Kompatibilitas

Dibuat untuk Odoo 12 sampai 15 (`/longpolling`). Odoo 16 ke atas memakai
`/websocket` dan `gevent_port`; keduanya ada di file sebagai komentar. Butuh
nginx 1.19.4 atau lebih baru untuk `ssl_reject_handshake`.

## Butuh bantuan memasangnya?

Karisma Technologies bisa memasang pengamanan ini di server Odoo produksi
Anda: menyetel batas sesuai jaringan kantor, memindahkan Odoo ke mode
multi-proses, memasang peringatan Telegram, backup terenkripsi ke cloud, dan
laporan status server berkala. Hubungi kami di
[prautomo@karismatech.com](mailto:prautomo@karismatech.com) atau kunjungi
[karismatech.com](https://karismatech.com).

## Lisensi

MIT. Dibuat oleh [Karisma Technologies](https://karismatech.com).
