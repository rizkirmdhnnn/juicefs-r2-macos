# JuiceFS + Cloudflare R2 di macOS

File system POSIX di atas Cloudflare R2, ter-mount di Finder sebagai drive
jaringan — **tanpa macFUSE, tanpa kernel extension, tanpa reboot**.

Semuanya berjalan di Docker. Cukup isi kredensial R2, jalankan satu perintah,
lalu volume muncul di Finder.

```
Finder (macOS)
   │  SMB
   ▼
┌─────────────────────────────┐        ┌──────────────┐
│  Container jfs-client       │        │  Cloudflare  │
│  ┌───────┐   ┌───────────┐  │ ─────► │      R2      │
│  │ Samba │──►│  JuiceFS  │  │  data  │  (object)    │
│  └───────┘   └─────┬─────┘  │        └──────────────┘
└────────────────────┼────────┘
                     │ metadata
                     ▼
              ┌─────────────┐
              │    Redis    │
              └─────────────┘
```

JuiceFS memisahkan **data** dan **metadata**. Data mentah dipecah jadi block
4 MiB dan disimpan di R2; struktur file system (nama, direktori, permission,
peta block) hidup di Redis. Hasilnya file system POSIX sungguhan — bukan
sekadar bucket yang ditempelkan seperti s3fs.

## Kenapa R2, bukan S3

**Egress gratis.** Setiap cache miss menarik data keluar dari bucket. Kalau
compute-mu bukan di AWS — laptop, on-prem, cloud lain — egress S3 bisa jadi
komponen biaya terbesar. Di R2 nol.

| 500 GB, baca 2 TB/bulan | Biaya/bulan |
|---|---|
| R2 | **$7,35** |
| S3 (compute di AWS) | $11,77 |
| S3 (compute di luar AWS) | **$182,77** |

## Yang kamu dapat

- Volume POSIX di Finder lewat SMB, drag-and-drop seperti drive biasa
- Cache baca lokal — pembacaan berulang ~40× lebih cepat daripada tarik ulang
- Trash 1 hari untuk semua penghapusan, dari jalur mana pun
- Backup metadata tiga lapis, dua di antaranya otomatis
- Tidak ada port yang terbuka ke jaringan lokal

## Prasyarat

- macOS dengan **[OrbStack](https://orbstack.dev)** (disarankan) atau Docker Desktop
- Akun Cloudflare dengan R2 aktif
- Bucket R2 dan API token berizin **Object Read & Write**

## Mulai

```bash
git clone <url-repo-ini> juicefs-lab
cd juicefs-lab
cp .env.example .env
```

Isi `.env`:

```env
R2_ACCOUNT_ID=         # 32 karakter hex — BUKAN URL endpoint
R2_BUCKET=             # nama bucket
R2_ACCESS_KEY=         # 32 karakter hex
R2_SECRET_KEY=         # 64 karakter hex
SMB_PASSWORD=          # ganti dari default!
```

Jalankan:

```bash
docker compose up -d
docker compose logs -f juicefs
```

Volume otomatis di-format saat pertama kali dijalankan. Banner akan muncul:

```
==================================================
 JuiceFS siap
   Mount   : /mnt/jfs
   Trash   : 1 hari
   Backup  : tiap 1h ke R2 + saat berhenti ke /dumps
   SMB     : smb://jfs-client.orb.local/jfs  (user: jfs)
==================================================
```

### Mendapatkan kredensial R2

1. Dashboard Cloudflare → **R2 Object Storage** → buat bucket
2. **Manage R2 API Tokens** → **Create Account API token**
3. Permission **Object Read & Write**, scope-kan ke bucket itu saja
4. Salin **Access Key ID** dan **Secret Access Key** — secret hanya muncul sekali

`R2_ACCOUNT_ID` hanya 32 karakter hex-nya. Jangan tempel URL endpoint lengkap —
compose merakitnya sendiri.

## Akses dari Finder

Tekan **⌘K** di Finder, masukkan:

```
smb://jfs-client.orb.local/jfs
```

Pilih **Registered User**, isi kredensial dari `.env`. Volume muncul di
`/Volumes/jfs`.

Dari terminal:

```bash
mount_smbfs "//jfs:PASSWORD@jfs-client.orb.local/jfs" /tmp/jfsmnt
```

## Konfigurasi

Semua lewat `.env`:

| Variabel | Default | Keterangan |
|---|---|---|
| `R2_ACCOUNT_ID` | — | 32 hex, wajib |
| `R2_BUCKET` | — | wajib |
| `R2_ACCESS_KEY` | — | wajib |
| `R2_SECRET_KEY` | — | wajib |
| `R2_JURISDICTION` | kosong | `eu` atau `fedramp` |
| `CACHE_SIZE` | `10240` | cache baca lokal, MiB |
| `TRASH_DAYS` | `1` | masa simpan file terhapus |
| `BACKUP_META` | `1h` | interval backup otomatis ke R2 |
| `BACKUP_ON_STOP` | `true` | dump metadata saat container berhenti |
| `KEEP_SHUTDOWN_DUMPS` | `5` | rotasi dump tersebut |
| `ENABLE_SMB` | `true` | server Samba |
| `ENABLE_WEBDAV` | `false` | server WebDAV (cadangan) |
| `SMB_USER` / `SMB_PASSWORD` | `jfs` / `juicefs123` | **ganti password-nya** |
| `WEBDAV_USER` / `WEBDAV_PASSWORD` | `jfs` / `jfs` | dipakai kalau WebDAV menyala |
| `WEBDAV_ADDR` | `0.0.0.0:9007` | alamat listen WebDAV |
| `META_URL` | `redis://redis:6379/2` | metadata engine |
| `VOL_NAME` | `myjfs-r2` | nama volume JuiceFS |

`CACHE_SIZE` adalah knob paling berpengaruh ke performa. `TRASH_DAYS` selalu
direkonsiliasi ke volume yang sudah ada, bukan hanya saat format.

Kredensial hanya divalidasi untuk layanan yang menyala — kalau
`ENABLE_WEBDAV=false`, `WEBDAV_USER`/`WEBDAV_PASSWORD` tidak wajib diisi.

### Yang tidak bisa diatur dari `.env`

`entrypoint.sh` juga membaca `CACHE_DIR` dan `MOUNT_POINT`, tapi keduanya
**sengaja tidak diteruskan** lewat compose karena terikat ke berkas lain:

| Variabel | Nilai tetap | Terikat pada |
|---|---|---|
| `CACHE_DIR` | `/var/jfsCache` | volume `jfs-cache` di `docker-compose.yml` |
| `MOUNT_POINT` | `/mnt/jfs` | `path = /mnt/jfs` di `smb.conf` |

Mengubahnya hanya lewat `.env` tidak akan berpengaruh. Kalau memang perlu,
ubah juga berkas terkaitnya.

## Struktur project

| Berkas | Isi |
|---|---|
| `docker-compose.yml` | service, volume, environment |
| `Dockerfile` | image `juicedata/mount` + Samba |
| `entrypoint.sh` | logika startup dan shutdown |
| `smb.conf` | konfigurasi Samba untuk macOS |
| `backup-meta.sh` | dump metadata + rotasi |
| `launchd/` | template penjadwalan backup (opsional) |
| `dumps/` | tujuan dump metadata |
| `shared/` | jembatan berkas macOS ↔ container |

Logika startup ada di `entrypoint.sh`, bukan inline di compose — bisa
di-`shellcheck` dan bebas dari kerepotan `$$` escaping. Setelah mengeditnya:

```bash
docker compose up -d --build juicefs
```

---

## Temuan penting

Bagian ini merangkum hal-hal yang tidak terdokumentasi dengan baik di tempat
lain, semuanya diverifikasi langsung pada JuiceFS 1.4.0.

### Dokumentasi JuiceFS soal batasan R2 sudah usang

Dokumentasi resmi JuiceFS — termasuk di tag v1.4.0 — masih menyatakan:

> Cloudflare R2 `ListObjects` API is not fully S3 compatible (result list is not
> sorted), so some features of JuiceFS do not work. For example, `juicefs gc`,
> `juicefs fsck`, `juicefs sync`, `juicefs destroy`. And when using
> `juicefs mount`, you need to disable automatic-backup by adding
> `--backup-meta 0`.

**Peringatan itu tidak lagi berlaku.**
[PR #6389](https://github.com/juicedata/juicefs/pull/6389) — *"allow unordered
list in fsck/backup/gc/destroy commands"* — di-merge 26 September 2025 dan
sudah masuk v1.4.0 (438 commit di belakangnya). Dokumentasinya tidak pernah
diperbarui.

Hasil pengujian langsung:

| Yang diuji | Hasil |
|---|---|
| ListObjectsV2 — 476 key, 1 halaman | ✅ terurut benar |
| ListObjectsV2 — 1076 key, **2 halaman** | ✅ terurut, 1076 unik, tanpa duplikat |
| `juicefs fsck` | ✅ 474 block, 345 slice, tanpa error |
| `juicefs gc` / `gc --delete` | ✅ 0 leaked, data utuh |
| `juicefs sync` | ✅ 20 object, 0 gagal |
| `juicefs destroy` | ✅ 479 object terhapus, bucket jadi 0 B |
| `--backup-meta 1h` | ✅ dump muncul di R2 setelah 8 menit |

Perlakukan R2 sebagai object storage biasa. Tidak ada perintah yang perlu
dihindari, dan `--backup-meta 0` tidak diperlukan.

Catatan: Cloudflare tidak pernah *menjanjikan* urutan leksikografis di
dokumentasinya. Yang terbukti di atas adalah perilaku saat ini, bukan kontrak.

### `--enable-xattr` wajib kalau memakai Samba

Samba menyimpan metadata macOS lewat modul `streams_xattr`, yang butuh
dukungan extended attribute dari filesystem. **JuiceFS mematikan xattr secara
default.**

Tanpa flag itu, `setxattr` gagal dengan `Errno 95: Operation not supported`,
dan Samba jatuh ke mode membuat berkas `._namafile` sungguhan — mengotori
storage dan memboroskan operasi Class A di R2.

| | Tanpa `--enable-xattr` | Dengan |
|---|---|---|
| Salin 1 berkas dari Finder | `._namafile` 4 KB ikut tersimpan | tidak ada |
| 10.000 berkas | 10.000 object sampah | 0 |

### Finder macOS memblokir `smb://localhost`

macOS menganggapnya koneksi ke dirinya sendiri dan memblokirnya di lapisan
NetFS. Errornya menyesatkan:

> There was a problem connecting to the server "localhost".
> The server may not exist or it is unavailable at this time.

Padahal server berjalan normal — log Samba tidak mencatat percobaan koneksi
sama sekali, karena permintaannya tidak pernah keluar dari macOS.

`mount_smbfs` dari terminal tetap bisa pakai `localhost` karena melewati
lapisan itu. **Gejala khasnya: CLI jalan, Finder gagal.**

Solusinya memakai nama host OrbStack (`jfs-client.orb.local`) atau IP container.

### `/mnt/jfs` akan terlihat kosong dari macOS

`/mnt/jfs` adalah FUSE mount **di dalam container**. Di macOS, path `/mnt`
bahkan tidak ada.

Lewat file browser OrbStack (`~/OrbStack/docker/containers/jfs-client/mnt/jfs`)
juga terlihat kosong. Itu normal: OrbStack mengekspos *layer filesystem*
container, sedangkan FUSE mount adalah mount kernel di mount namespace —
bukan bagian dari filesystem. Sebagai pembanding, `/var/jfsCache` tetap
terlihat isinya.

Bind mount juga tidak menolong. Mount FUSE di dalam folder yang di-bind dari
macOS tetap tidak tembus, karena bind mount mengalir satu arah: macOS → VM →
container. Satu-satunya jalan keluar adalah membagikannya lewat protokol
jaringan — itulah fungsi Samba di sini.

### SMB lebih aman daripada WebDAV untuk Finder

JuiceFS menyediakan server WebDAV bawaan, dan Finder bisa me-mount-nya. Tapi
dalam pengujian, Finder lewat WebDAV pernah **menghapus seluruh isi volume**
saat operasi penyalinan berkas besar. Semuanya bisa dipulihkan dari `.trash`,
tapi itu bukan risiko yang layak diambil.

Apple memakai SMB sebagai protokol utama macOS, jadi Finder memperlakukannya
sebagai volume kelas satu. WebDAV di repo ini default-nya **mati**, tersedia
sebagai cadangan lewat `ENABLE_WEBDAV=true`.

---

## Backup metadata

Metadata adalah titik kegagalan tunggal. Kalau Redis hilang, data di R2 masih
utuh tapi berubah jadi blok anonim yang tidak bisa dirangkai kembali.

Repo ini memasang tiga lapis:

### Lapis 1 — ke R2, tiap jam

Ditangani JuiceFS sendiri lewat `--backup-meta 1h`. Tersimpan ter-gzip di
`<volume>/meta/` dengan rotasi berjenjang otomatis.

### Lapis 2 — ke disk lokal, saat container berhenti

Setiap `docker compose down` / `stop`, entrypoint mem-`juicefs dump` ke
`dumps/shutdown-YYYYMMDD-HHMMSS.json.gz`.

Ini menutup jendela antara backup otomatis terakhir dan saat container mati.
Dijalankan **setelah** umount supaya menangkap kondisi final, dengan
`timeout 60` agar tidak menahan `stop_grace_period`.

Terukur: `compose stop` 0,31 detik, `compose down` penuh 0,89 detik.

### Lapis 3 — manual atau terjadwal

```bash
./backup-meta.sh          # backup sekarang
tail dumps/backup.log     # riwayat
```

Retensi 7 harian + 4 mingguan (~5 KB per berkas). Skrip **gagal keras** kalau
container mati — tercatat di log dengan exit code 1, dan backup lama tidak
tertimpa. Isi dump juga diverifikasi mengandung `FSTree` + `Setting` sebelum
menggantikan yang lama.

Template launchd untuk penjadwalan harian tersedia di `launchd/` — lihat
`launchd/README.md`. Tidak dipasang secara default.

### Memulihkan

Prosedur lengkap ada di [`dumps/CARA-RESTORE.md`](dumps/CARA-RESTORE.md).

Ringkasnya:

```bash
juicefs load redis://redis:6379/2 dump.json
juicefs config redis://redis:6379/2 --secret-key "$R2_SECRET_KEY"   # ← WAJIB
```

Langkah kedua paling mudah terlewat. `juicefs dump` **selalu** membuang secret
key demi keamanan (`Secret key is removed for the sake of safety`), jadi tanpa
langkah itu pemulihan akan tampak gagal padahal hanya kurang kredensial.

## Trash

`TRASH_DAYS=1` berlaku untuk **semua jalur penghapusan** — Finder, terminal,
aplikasi mana pun. JuiceFS mencegatnya di lapisan filesystem, bukan protokol.

Format nama: `<inode-induk>-<inode>-<nama-asli>`.

Trash sengaja **disembunyikan dari Finder** lewat `veto files = /.trash/` di
`smb.conf`. Ini jaring pengaman terakhir; kalau bisa dijangkau Finder, satu
operasi ceroboh bisa menghapusnya bersamaan dengan datanya.

Memulihkan berkas lewat container:

```bash
docker compose exec juicefs find /mnt/jfs/.trash -type f
docker compose exec juicefs mv /mnt/jfs/.trash/<...>/<berkas> /mnt/jfs/
```

Berkas di trash **tetap memakan storage R2** selama masa simpan.

## Keamanan jaringan

Compose ini **sengaja tidak mem-publish port SMB (445) maupun WebDAV (9007)**.
Keduanya tetap terjangkau dari macOS lewat routing OrbStack, tanpa membuka
apa pun ke jaringan lokal. Redis diikat ke `127.0.0.1` saja.

Docker mengikat ke **semua interface** kalau ditulis `"445:445"` — termasuk
Wi-Fi. Yang paling berbahaya adalah Redis, karena tanpa password sama sekali:
siapa pun di jaringan yang sama bisa menghapus seluruh metadata.

```yaml
ports:
  - "127.0.0.1:9007:9007"   # benar
  - "9007:9007"             # SALAH — terbuka ke seluruh LAN
```

Periksa paparan kapan saja:

```bash
LANIP=$(ipconfig getifaddr en0)
for p in 445 9007 6380; do
  nc -z -G 2 $LANIP $p && echo "$p TERBUKA" || echo "$p tertutup"
done
```

Belum dikeraskan: password SMB default masih lemah (ganti di `.env`), dan
Redis belum memakai `requirepass` — aman selama hanya loopback.

## Performa

MacBook Apple Silicon, OrbStack, R2 default jurisdiction, koneksi rumahan
Indonesia:

| | Hasil |
|---|---|
| Tulis 20 MiB ke R2 | 2,79 s (~7,5 MB/s) |
| Baca 20 MiB dingin dari R2 | 2,34 s (~8,6 MB/s) |
| **Baca 20 MiB dari cache lokal** | **0,056 s (~357 MB/s)** |
| Stat berkas (metadata) | 29.557 ops/s |

Selisih baca dingin vs hangat: **42×**. Performa JuiceFS nyaris seluruhnya
ditentukan cache hit rate, bukan kecepatan object storage — itu sebabnya
`CACHE_SIZE` adalah pengaturan paling berharga.

Perhatikan juga `Stat berkas`: operasi metadata tetap ngebut walau data ada di
seberang lautan, karena dilayani Redis lokal. Inilah keuntungan arsitektur
pemisahan data/metadata yang tidak bisa diberikan s3fs.

## Biaya

R2: storage $0,015/GB-bulan, Class A (tulis/list) $4,50/juta, Class B (baca)
$0,36/juta, **egress gratis**. Gratis 10 GB + 1 juta Class A + 10 juta Class B
per bulan.

Pada skala ratusan GB, free tier operasi menelan hampir semua pembacaan —
praktis kamu hanya membayar storage.

Yang perlu diperhatikan: **banyak berkas kecil**. Tiap berkas < 4 MiB tetap
jadi minimal satu object. Mengunggah 5 juta berkas kecil ≈ $19 sekali bayar
untuk operasi Class A. Blok lebih besar (`--block-size`, hanya bisa diatur saat
format) memangkas jumlah operasi tapi menambah read amplification.

## Perintah berguna

```bash
docker compose exec juicefs bash        # masuk container
META="redis://redis:6379/2"

juicefs status $META            # info volume & sesi aktif
juicefs profile /mnt/jfs        # operasi FUSE real-time — alat debug terbaik
juicefs bench /mnt/jfs -p 4     # benchmark
juicefs info /mnt/jfs/berkas    # lihat chunk/slice/block
juicefs warmup /mnt/jfs/data    # paksa isi cache
juicefs gc $META --compact      # kompaksi slice terfragmentasi
```

Memantau pertumbuhan metadata:

```bash
docker compose exec redis redis-cli info memory | grep used_memory_human
```

## Troubleshooting

**Finder gagal konek, error "server may not exist"**
Pakai `smb://jfs-client.orb.local/jfs`, bukan `localhost`. Kalau masih gagal,
hapus entri `localhost` bertipe *network password* di Keychain Access.

**Finder gagal padahal `mount_smbfs` berhasil**
macOS menolak me-mount share SMB yang sama dua kali. Cek `mount | grep smbfs`
lalu `umount` yang tidak dipakai.

**Muncul berkas `._namafile` di storage**
`--enable-xattr` tidak aktif. Periksa proses mount di container.

**`/mnt/jfs` kosong dari macOS**
Normal — lihat bagian Temuan penting.

**Container gagal start**
`docker compose logs juicefs`. Kalau `.env` kurang lengkap, compose berhenti
dengan pesan variabel mana yang kosong.

## Batasan yang perlu diketahui

**Redis menyimpan metadata di RAM**, sekitar 200 byte per berkas. Untuk jutaan
berkas ini jadi mahal:

| Jumlah berkas | RAM Redis |
|---|---|
| 100.000 | ~20 MB |
| 1 juta | ~200 MB |
| 10 juta | ~2 GB |

Di atas itu, pertimbangkan **PostgreSQL** — metadata pindah ke disk dengan
RAM proses tetap. Konsekuensinya 2,6–3,9× lebih lambat untuk operasi tulis
metadata (terukur, dengan durabilitas disetarakan). Ganti lewat `META_URL`.

**Redis di sini satu container tanpa replika.** Untuk pemakaian serius,
pindahkan ke instance dengan persistence dan replikasi yang benar.

**Random write intensif bukan kekuatan JuiceFS.** Overwrite membuat slice baru
(copy-on-write), dan fragmentasi memperlambat pembacaan sampai compaction
berjalan. Cocok untuk write-once-read-many: dataset, arsip, media, backup.

**Jangan `docker compose down -v`.** Itu menghapus volume Redis dan seluruh
file system hilang meski object masih utuh di R2. `docker compose down` biasa
aman — sudah diverifikasi menjaga metadata identik sampai level daftar key.

## Rujukan

- [Dokumentasi JuiceFS](https://juicefs.com/docs/community/introduction/)
- [Arsitektur JuiceFS](https://juicefs.com/docs/community/architecture)
- [Cloudflare R2](https://developers.cloudflare.com/r2/)
- [OrbStack](https://orbstack.dev)
