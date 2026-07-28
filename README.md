# JuiceFS + Cloudflare R2

File system POSIX di atas Cloudflare R2. **Redis** sebagai metadata engine,
**R2** sebagai object storage, **JuiceFS client** dalam container Linux.
Tidak butuh macFUSE, tidak butuh reboot.

## Struktur file

| File | Isi |
|---|---|
| `docker-compose.yml` | definisi service, volume, environment |
| `Dockerfile` | image = juicedata/mount + Samba |
| `entrypoint.sh` | **logika startup**: format → mount → WebDAV → Samba |
| `smb.conf` | konfigurasi Samba (tuning macOS) |
| `.env` | kredensial R2 + SMB (jangan di-commit) |
| `shared/` | jembatan Mac ↔ container |
| `dumps/` | tujuan `juicefs dump` |

Logika startup ada di **`entrypoint.sh`**, bukan inline di compose — lebih
mudah dibaca, bisa di-`shellcheck`, dan bebas dari kerepotan `$$` escaping
milik compose. Setelah mengeditnya:

```bash
docker compose up -d --build juicefs
```

Semua nilai yang dulu hardcoded kini bisa ditimpa lewat `.env`:
`META_URL`, `VOL_NAME`, `TRASH_DAYS`, `BACKUP_META`, `CACHE_SIZE`.

## Jalankan / matikan

```bash
cd ~/juicefs-lab

docker compose up -d           # nyalakan
docker compose up -d --build   # setelah edit entrypoint.sh / smb.conf
docker compose ps              # cek status
docker compose logs -f juicefs
docker compose down            # matikan (data & metadata tetap ada)
```

`entrypoint.sh` memasang trap SIGTERM yang **melepas mount lebih dulu** saat
container dihentikan, sehingga JuiceFS sempat menuntaskan flush ke R2.
Sebelum ini prosesnya cuma `tail -f /dev/null` yang tidak melakukan apa-apa —
data di buffer tulis yang belum terunggah bisa hilang saat `down`.

> ⚠️ **Jangan `docker compose down -v`.** Itu menghapus Redis, dan metadata
> hilang = seluruh file system hilang meski semua object masih utuh di R2.
> Kalau itu terjadi, bersihkan bucket dengan `juicefs destroy` (jalan normal
> di v1.4.0) lalu format ulang. Backup dulu — lihat bagian Backup metadata.

## ⚠️ Kenapa `/mnt/jfs` kosong kalau dilihat dari Mac

`/mnt/jfs` adalah **FUSE mount di dalam container**, bukan direktori di macOS.
Di Mac, path `/mnt` bahkan tidak ada sama sekali.

Lewat OrbStack Finder (`~/OrbStack/docker/containers/jfs-client/mnt/jfs`) juga
akan terlihat **kosong**. Itu normal, bukan bug: OrbStack mengekspos *layer
filesystem* container, sedangkan FUSE mount adalah mount kernel di mount
namespace container — bukan bagian dari filesystem. Buktinya, `/var/jfsCache`
lewat OrbStack tetap terlihat isinya.

Hasilnya identik dengan menjalankan `umount /mnt/jfs`: direktori kosong.
File-nya hanya "ada" saat dilihat melalui lapisan FUSE.

**Untuk akses dari Finder, pakai SMB** (lihat bawah).

## Akses dari Finder macOS — SMB (utama)

Samba jalan otomatis di port 445 bersama mount.

1. Di Finder tekan **⌘K** (Go → Connect to Server)
2. Isi: **`smb://jfs-client.orb.local/jfs`**
3. Pilih **Registered User**, isi `SMB_USER` / `SMB_PASSWORD` dari `.env`
   (default `jfs` / `juicefs123`)

### ⚠️ JANGAN pakai `smb://localhost` di Finder

Finder macOS **memblokir koneksi SMB ke `localhost`/`127.0.0.1`** — ia
menganggapnya koneksi ke dirinya sendiri. Errornya menyesatkan:

> There was a problem connecting to the server "localhost".
> The server may not exist or it is unavailable at this time.

Padahal server jalan normal. Buktinya: log Samba **tidak mencatat percobaan
koneksi sama sekali** — permintaannya tidak pernah keluar dari macOS.

`mount_smbfs` dari terminal tetap bisa pakai `localhost` karena melewati
lapisan NetFS yang memblokir itu. Jadi kalau CLI jalan tapi Finder gagal,
inilah penyebabnya.

Solusinya: pakai nama OrbStack `jfs-client.orb.local` (stabil walau IP
berubah) atau IP container langsung (`docker inspect jfs-client --format
'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`).

### Hanya satu mount per share

macOS menolak me-mount share SMB yang sama dua kali. Kalau sudah ter-mount
di terminal, Finder akan gagal. Cek dengan `mount | grep smbfs`, lalu
`umount` yang tidak dipakai.

Dari terminal:

```bash
mkdir -p /tmp/jfsmnt
mount_smbfs "//jfs:juicefs123@jfs-client.orb.local/jfs" /tmp/jfsmnt
umount /tmp/jfsmnt
```

### Kenapa SMB, bukan WebDAV

Finder macOS memperlakukan SMB sebagai volume kelas satu. WebDAV pernah
menyebabkan seluruh isi volume terhapus di lab ini (terselamatkan `.trash`).

### `--enable-xattr` itu WAJIB

Ini yang paling mudah terlewat. Samba menyimpan metadata macOS lewat modul
`streams_xattr`, yang butuh dukungan extended attribute dari filesystem.
JuiceFS **mematikan xattr secara default** (`--enable-xattr` default `false`).

Tanpa flag itu, `setxattr` gagal dengan `Errno 95: Operation not supported`,
dan Samba jatuh ke mode membuat file `._namafile` sungguhan — mengotori
storage dan memboroskan operasi Class A di R2.

Terbukti di lab ini: sebelum flag → `._smbtest.bin` 4 KB tersimpan nyata;
sesudah flag → tidak ada file `._` sama sekali, metadata jadi xattr.

### Proteksi `.trash`

`smb.conf` memakai `veto files = /.trash/` sehingga Finder **tidak bisa
melihat atau menghapus** isi trash. Ini jaring pengaman terakhir di R2 —
jangan dilepas.

## Trash

Di `.env`:

```env
TRASH_DAYS=1     # default — berapa hari file terhapus disimpan
```

Terapkan dengan `docker compose up -d juicefs`. Nilainya **selalu
direkonsiliasi**, termasuk ke volume yang sudah ada — entrypoint memanggil
`juicefs config --trash-days` kalau nilainya berbeda. Banner saat start
menampilkan nilai yang berlaku.

(`--trash-days` di `juicefs format` hanya berlaku saat pembuatan volume. Tanpa
rekonsiliasi ini, mengubah `.env` akan diam-diam diabaikan pada volume lama —
lebih membingungkan daripada error.)

### Semua jalur hapus tertangkap

Diuji langsung: menghapus lewat **terminal di container** maupun lewat
**SMB dari Mac** sama-sama masuk `.trash`. JuiceFS mencegatnya di lapisan
filesystem, bukan protokol.

Format nama di trash: `<inode-induk>-<inode>-<nama-asli>`.

### Trash tidak terlihat dari Finder — disengaja

`smb.conf` memakai `veto files = /.trash/`. Finder tidak bisa melihat, membuka,
apalagi menghapus isinya. Ini jaring pengaman terakhir; kalau bisa dijangkau
Finder, satu operasi ceroboh bisa menghapusnya bersamaan dengan datanya.

Memulihkan file harus lewat container:

```bash
docker compose exec juicefs find /mnt/jfs/.trash -type f
docker compose exec juicefs \
  mv /mnt/jfs/.trash/2026-07-29-01/1-1026-namafile.txt /mnt/jfs/namafile.txt
```

### Yang perlu diingat

- File di trash **tetap memakan storage R2** selama masa simpan. Menghapus
  500 MB tidak langsung mengurangi tagihan.
- `TRASH_DAYS=0` mematikan trash — file hilang permanen tanpa cara memulihkan.
  Entrypoint akan memberi peringatan kalau kamu menyetelnya.
- Trash inilah yang menyelamatkan 671 MB saat Finder lewat WebDAV menghapus
  seluruh isi volume di lab ini.

## Saklar layanan

Di `.env`:

```env
ENABLE_SMB=true       # jalur utama Finder
ENABLE_WEBDAV=false   # cadangan, default MATI
```

Terapkan dengan `docker compose up -d juicefs`. Banner saat start menampilkan
status masing-masing, jadi tidak perlu menebak.

Menerima `true` / `1` / `yes` / `on` (huruf besar-kecil bebas).

### WebDAV — cadangan yang sengaja dimatikan

Dimatikan karena SMB menangani Finder dengan lebih baik, dan WebDAV yang
menganggur cuma memakan satu proses. Hidupkan kalau SMB bermasalah:

```bash
# .env → ENABLE_WEBDAV=true
docker compose up -d juicefs
curl -u jfs:jfs -X PROPFIND -H "Depth: 1" http://jfs-client.orb.local:9007/
```

⚠️ Finder macOS pernah menghapus seluruh isi volume lewat WebDAV di lab ini
(terselamatkan `.trash`). Pakai untuk baca/unduh saja — jangan menulis file
besar dari Finder lewat jalur ini.

## Titik akses

| Apa | Di mana |
|---|---|
| Shell di client | `docker compose exec juicefs bash` |
| Mount point | `/mnt/jfs` (**hanya di dalam container**) |
| Finder macOS | `smb://jfs-client.orb.local/jfs` via ⌘K |
| Bucket R2 | dashboard Cloudflare → R2 → `juicefs` → prefix `myjfs-r2/` |
| Redis metadata | `docker compose exec redis redis-cli -n 2` |
| Folder Mac ↔ container | `~/juicefs-lab/shared` → `/shared` |
| Backup metadata | `~/juicefs-lab/dumps` → `/dumps` |

Taruh file dari macOS di `shared/`, lalu di dalam container
`cp /shared/xxx /mnt/jfs/`.

## Konfigurasi

Semua di `.env` (sudah masuk `.gitignore`, jangan di-commit):

```env
R2_ACCOUNT_ID=<32 karakter hex, BUKAN URL>
R2_BUCKET=juicefs
R2_ACCESS_KEY=<Access Key ID>
R2_SECRET_KEY=<Secret Access Key>
R2_JURISDICTION=          # kosong, atau "eu" / "fedramp"
CACHE_SIZE=10240          # MiB — knob performa paling berpengaruh
```

Yang dijalankan compose di balik layar:

```bash
juicefs format \
  --storage s3 \
  --bucket https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET> \
  --access-key ... --secret-key ... --trash-days 1 \
  redis://redis:6379/2 myjfs-r2

juicefs mount redis://redis:6379/2 /mnt/jfs \
  --cache-dir /var/jfsCache --cache-size $CACHE_SIZE \
  --backup-meta 1h --enable-xattr --background
```

R2 dipakai lewat `--storage s3` (bukan tipe khusus), format path-style.

### Kredensial R2

1. Dashboard Cloudflare → **R2 Object Storage** → buat bucket
2. **Manage R2 API Tokens** → **Create Account API token**
3. Permission: **Object Read & Write**, scope-kan ke bucket itu saja
4. Salin **Access Key ID** (32 hex) dan **Secret Access Key** (64 hex) —
   secret hanya muncul sekali

## Soal "batasan R2" — dokumentasi JuiceFS sudah USANG

Dokumentasi resmi JuiceFS (termasuk di tag v1.4.0) masih memuat peringatan ini:

> Cloudflare R2 `ListObjects` API is not fully S3 compatible (result list is not
> sorted), so some features of JuiceFS do not work. For example, `juicefs gc`,
> `juicefs fsck`, `juicefs sync`, `juicefs destroy`. And when using
> `juicefs mount`, you need to disable automatic-backup by adding
> `--backup-meta 0`.

**Peringatan itu tidak lagi berlaku untuk v1.4.0.**

| | |
|---|---|
| Issue [#3144](https://github.com/juicedata/juicefs/issues/3144) | ditutup COMPLETED, 26 Sep 2025 |
| PR [#6389](https://github.com/juicedata/juicefs/pull/6389) | *"allow unordered list in fsck/backup/gc/destroy commands"* — merged 26 Sep 2025 |
| File yang diubah | `gc.go`, `fsck.go`, `destroy.go`, `format.go`, `vfs/backup.go` |
| Masuk v1.4.0? | ya — v1.4.0 berjarak 438 commit di depan fix itu |
| Dokumentasi | **tidak pernah diperbarui** |

### Hasil pengujian langsung (28 Juli 2026, juicefs 1.4.0 + R2)

| Yang diuji | Hasil |
|---|---|
| ListObjectsV2 — 476 key, 1 halaman | ✅ terurut benar |
| ListObjectsV2 — 1076 key, **2 halaman** | ✅ terurut sempurna, 1076 unik, tanpa duplikat |
| `juicefs fsck` | ✅ 474 block, 345 slice, tanpa error |
| `juicefs gc` | ✅ 0 leaked |
| `juicefs gc --delete` | ✅ jalan, data utuh (checksum identik) |
| `juicefs sync` | ✅ 20 object, 0 gagal |
| `juicefs destroy` | ✅ 479 object terhapus, bucket jadi 0 B |
| `--backup-meta 1h` | ✅ `dump-2026-07-28-175943.json.gz` muncul di R2 setelah 8 menit |

Kesimpulan: **perlakukan R2 sebagai object storage biasa.** Tidak ada perintah
yang perlu dihindari.

### Yang tetap perlu diingat

Cloudflare **tidak pernah menjanjikan** urutan leksikografis di dokumentasinya —
mereka hanya menyatakan ListObjectsV2 "terimplementasi". Jadi yang terbukti di
atas adalah *perilaku hari ini*, bukan *kontrak*. Verifikasi ulang setelah
upgrade JuiceFS atau perubahan besar di R2.

Pengujian juga memakai pola key seragam (`chunks/0/25/25117_0_8`). Laporan
komunitas soal urutan aneh di R2 mungkin terkait karakter khusus atau delimiter
yang tidak muncul di pola JuiceFS.

## Backup metadata — dua lapis

### Lapis 1 — otomatis ke R2 (tiap 1 jam)

Ditangani JuiceFS sendiri lewat `--backup-meta 1h`. Tersimpan ter-gzip di
`myjfs-r2/meta/`, rotasi berjenjang otomatis. Tidak perlu diapa-apakan.

### Lapis 2 — dump otomatis saat container berhenti

Setiap `docker compose down` / `stop`, entrypoint mem-`juicefs dump` ke
`dumps/shutdown-YYYYMMDD-HHMMSS.json.gz` sebelum keluar.

Kenapa perlu: `--backup-meta` hanya jalan tiap 1 jam. Kalau container dimatikan
59 menit setelah backup terakhir, perubahan metadata di jendela itu **cuma ada
di Redis**. Selama volume `redis-data` utuh tidak masalah — tapi kalau rusak
atau kena `down -v`, perubahan itu hilang dan file yang dibuat di jendela itu
jadi object yatim di R2.

```env
BACKUP_ON_STOP=true        # matikan dengan false
KEEP_SHUTDOWN_DUMPS=5      # rotasi, simpan 5 terbaru
```

Dijalankan **setelah** umount supaya menangkap kondisi final. Diberi
`timeout 60` agar tidak menahan shutdown melebihi `stop_grace_period`.
Kalau Redis sudah mati duluan, gagal dengan peringatan — tidak menggantung.

Diuji: `compose stop` 0,31 detik, `compose down` penuh 0,89 detik, keduanya
menghasilkan dump valid.

### Lapis 3 — dump manual / terjadwal

`backup-meta.sh`

`backup-meta.sh` — jalankan kapan saja:

```bash
./backup-meta.sh          # backup sekarang
tail dumps/backup.log     # riwayat
```

Kenapa perlu: lapis 1 tersimpan di **bucket yang sama** dengan datanya. Kalau
akun R2 bermasalah atau bucket terhapus, backup ikut hilang.

Retensi 7 harian + 4 mingguan (~5 KB per file). Skrip **gagal keras** kalau
container mati — tercatat di log dengan exit code 1, dan backup lama tidak
tertimpa. Dump juga diverifikasi berisi `FSTree` + `Setting` sebelum
menggantikan yang lama.

> **Belum dijadwalkan otomatis.** Template launchd tersedia di
> `launchd/com.juicefs.lab.backup.plist` — lihat `launchd/README.md` untuk
> cara memasangnya kalau nanti dibutuhkan. Saat ini tidak ada agent yang
> terdaftar di sistem.

### Memulihkan

Prosedur lengkap ada di **`dumps/CARA-RESTORE.md`** — ditaruh di sana supaya
mudah ditemukan saat panik.


Sudah **otomatis**: mount memakai `--backup-meta 1h`, JuiceFS mem-backup
metadata ke `myjfs-r2/meta/` di R2 tiap jam dan merotasi yang lama sendiri.
Terverifikasi jalan.

Untuk lapis kedua (jaga-jaga kalau akun R2 bermasalah), dump lokal berkala:

```bash
docker compose exec juicefs \
  juicefs dump redis://redis:6379/2 /dumps/meta-$(date +%F).json
```

### Prosedur pemulihan — sudah diuji

```bash
# 1. Restore metadata ke database kosong
juicefs load redis://redis:6379/5 /dumps/meta-2026-07-28.json

# 2. Pasang ulang secret key — WAJIB, dump sengaja membuangnya
juicefs config redis://redis:6379/5 --secret-key <R2_SECRET_KEY>

# 3. Mount seperti biasa
juicefs mount redis://redis:6379/5 /mnt/restore --enable-xattr -d
```

Langkah 2 paling mudah terlewat. `juicefs dump` selalu membuang secret key
(`Secret key is removed for the sake of safety`), jadi tanpa langkah itu restore
akan terlihat gagal padahal cuma kurang kredensial.

Untuk pemakaian serius: pindahkan Redis ke instance dengan persistence +
replika, bukan single container seperti di sini.

## Perintah JuiceFS penting

Dari dalam container (`docker compose exec juicefs bash`):

```bash
META="redis://redis:6379/2"

juicefs status $META           # info volume, sesi client aktif
juicefs bench /mnt/jfs -p 4    # benchmark
juicefs profile /mnt/jfs       # ← operasi FUSE real-time, alat debug terbaik
juicefs warmup /mnt/jfs/data   # paksa isi cache lokal
juicefs info /mnt/jfs/file     # lihat chunk/slice/block sebuah file
juicefs config $META           # lihat / ubah konfigurasi volume
juicefs dump $META /dumps/m.json   # backup metadata

# Semua perintah di atas JALAN NORMAL di R2 (v1.4.0) — sudah diuji
```

## Eksperimen yang layak dicoba

### 1. Lihat file dipecah jadi block
```bash
dd if=/dev/urandom of=/mnt/jfs/a.bin bs=1M count=20
juicefs info /mnt/jfs/a.bin
```
Lalu buka dashboard R2 → bucket `juicefs` → prefix `myjfs-r2/chunks/`.
Ada 5 object 4 MiB. Nama object = `<sliceID>_<indexBlock>_<ukuranByte>`.

### 2. Buktikan copy-on-write
```bash
dd if=/dev/urandom of=/mnt/jfs/a.bin bs=1k count=1 seek=5000 conv=notrunc
```
Cek R2 lagi: block lama **tidak berubah**, muncul object kecil baru (slice 2).
Overwrite tidak pernah menimpa object — ia menumpuk slice.

### 3. Ukur efek cache (paling penting)
```bash
# baca dingin
docker compose stop juicefs
docker run --rm -v juicefs-lab_jfs-cache:/c alpine rm -rf /c/
docker compose up -d juicefs && sleep 9
docker compose exec juicefs bash -c 'time md5sum /mnt/jfs/a.bin'

# baca hangat
docker compose exec juicefs bash -c 'time md5sum /mnt/jfs/a.bin'
```

### 4. Amati operasi FUSE langsung
Dua terminal. A: `juicefs profile /mnt/jfs`. B: jalankan `cp`, `ls -R`, `dd`.
Cara tercepat memahami kenapa banyak file kecil itu mahal — tiap file kecil
= minimal 1 Class A operation di R2.

### 5. Metadata itu cuma database biasa
```bash
docker compose exec redis redis-cli -n 2 --scan --count 20 | head -30
docker compose exec redis redis-cli -n 2 dbsize
```
Buat file baru, jalankan lagi, lihat key bertambah.

## Angka nyata dari mesin ini

MacBook Apple Silicon, OrbStack, R2 (default jurisdiction), koneksi Indonesia:

| | Hasil |
|---|---|
| Tulis 20 MiB ke R2 | 2.79 s (~7.5 MB/s) |
| Baca 20 MiB dingin dari R2 | 2.34 s (~8.6 MB/s) |
| Baca 20 MiB dari cache lokal | 0.056 s (~357 MB/s) |

Selisih dingin vs hangat: **42×**. Di JuiceFS, performa nyaris seluruhnya
ditentukan cache hit rate — bukan kecepatan object storage. Itu sebabnya
`CACHE_SIZE` adalah knob paling berharga di `.env`.

~7–8 MB/s wajar untuk koneksi tunggal ke R2 dari Indonesia. Untuk naik,
tambah paralelisme — bukan masalah R2-nya.

## Biaya

R2: storage $0.015/GB-bulan, Class A (tulis/list) $4.50/juta,
Class B (baca) $0.36/juta, **egress gratis**.
Gratis 10 GB storage + 1 juta Class A + 10 juta Class B per bulan.

- Tulis 1 TB dengan block 4 MiB ≈ 262 ribu PUT ≈ $1.18 Class A
- Banyak file kecil = banyak Class A → biaya operasi bisa melebihi storage
- Blok lebih besar (`--block-size 16384`, satuan KiB) memangkas jumlah operasi,
  tapi menambah read amplification saat random read. Ukur dulu, jangan asal.
  Block size hanya bisa diatur saat `format`, tidak bisa diubah belakangan.

Egress gratis adalah alasan utama R2 cocok untuk JuiceFS — setiap cache miss
menarik data keluar bucket. Di S3 itu ~$90/TB kalau compute-mu bukan di AWS.

## Keamanan jaringan

Compose ini **sengaja tidak mem-publish port SMB (445) maupun WebDAV (9007)**.
Keduanya tetap terjangkau dari macOS lewat routing OrbStack di
`jfs-client.orb.local`, tanpa membuka apa pun ke jaringan WiFi.

Redis diikat ke `127.0.0.1:6380` saja.

### Kenapa ini penting

Docker mengikat port ke **semua interface** kalau ditulis `"445:445"`.
Di lab ini pernah terjadi: ketiga port (445, 9007, 6380) terbuka ke seluruh
WiFi. Yang paling berbahaya justru **Redis — tanpa password sama sekali**.
Siapa pun di jaringan yang sama bisa menghapus metadata, dan semua data di R2
langsung jadi blok anonim yang tak bisa dirangkai kembali.

Kalau suatu saat kamu perlu mem-publish port, selalu ikat ke loopback:

```yaml
ports:
  - "127.0.0.1:9007:9007"   # benar
  - "9007:9007"             # SALAH — terbuka ke seluruh LAN
```

Cek paparan kapan saja:

```bash
LANIP=$(ipconfig getifaddr en0)
for p in 445 9007 6380; do nc -z -G 2 $LANIP $p && echo "$p TERBUKA" || echo "$p tertutup"; done
```

### Pengerasan lanjutan yang belum dilakukan

- Password SMB masih `juicefs123` — ganti di `.env`
- Redis belum pakai `requirepass` (aman selama hanya loopback)

## Catatan

- Redis lab pakai port **6380** karena 6379 sudah dipakai Redis-nya Laravel Herd.
- Volume R2 memakai **Redis DB 2**. DB 1 sengaja dikosongkan (bekas MinIO).
- `.env` berisi kredensial dan sudah masuk `.gitignore`.
- `--trash-days 1`: file terhapus mampir dulu ke `/mnt/jfs/.trash` selama 1 hari
  dan **tetap memakan storage R2** selama itu.
