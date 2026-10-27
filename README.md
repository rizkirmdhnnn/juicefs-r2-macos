# JuiceFS + Cloudflare R2 di macOS

File system POSIX di atas Cloudflare R2, ter-mount di Finder sebagai drive
jaringan — **tanpa macFUSE, tanpa kernel extension, tanpa reboot**.

Semuanya berjalan di Docker. Isi kredensial R2, jalankan satu perintah, volume
muncul di Finder.

> **Ada dua jalur di repo ini.** Yang dijelaskan di bawah adalah jalur Docker +
> SMB: paling mudah dipasang, tidak menyentuh kernel. Jalur kedua memasang
> macFUSE dan me-mount langsung di macOS dengan Redis dari Homebrew — butuh
> Recovery Mode dan dua kali reboot, **tidak lebih cepat untuk berkas besar**,
> tapi metadata 1,37× lebih gesit dan volumenya muncul sebagai disk di Finder.
> Prosedur, pengukuran, dan cara migrasinya ada di
> [Mount native lewat macFUSE](docs/mount-native-macfuse.md).

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
4 MiB dan disimpan di R2; struktur file system hidup di Redis. Hasilnya file
system POSIX sungguhan — bukan bucket yang ditempelkan seperti s3fs.

R2 dipilih karena **egress-nya gratis**. Setiap cache miss menarik data keluar
bucket; kalau compute-mu bukan di AWS, egress S3 bisa jadi komponen biaya
terbesar. Rinciannya di [Performa dan biaya](docs/performa-dan-biaya.md).

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

Isi minimal empat baris di `.env`:

```env
R2_ACCOUNT_ID=         # 32 karakter hex — BUKAN URL endpoint
R2_BUCKET=             # nama bucket
R2_ACCESS_KEY=         # 32 karakter hex
R2_SECRET_KEY=         # 64 karakter hex
```

Ganti juga `SMB_PASSWORD` dari nilai default.

```bash
docker compose up -d
docker compose logs -f juicefs
```

Volume otomatis di-format saat pertama dijalankan:

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

Tekan **⌘K**, masukkan:

```
smb://jfs-client.orb.local/jfs
```

Pilih **Registered User**, isi kredensial dari `.env`. Volume muncul di
`/Volumes/jfs`.

> ⚠️ **Jangan pakai `smb://localhost`** — Finder memblokirnya dengan error yang
> menyesatkan. [Penjelasannya di sini](docs/temuan-teknis.md#3-finder-macos-memblokir-smblocalhost).

Dari terminal:

```bash
mount_smbfs "//jfs:PASSWORD@jfs-client.orb.local/jfs" /tmp/jfsmnt
umount /tmp/jfsmnt
```

> ⚠️ `/mnt/jfs` akan terlihat **kosong** kalau dibuka dari macOS atau file
> browser OrbStack. Itu normal — [kenapa](docs/temuan-teknis.md#4-mntjfs-akan-terlihat-kosong-dari-macos).

## Perintah sehari-hari

```bash
docker compose up -d           # nyalakan
docker compose up -d --build   # setelah edit entrypoint.sh / smb.conf
docker compose ps              # status
docker compose logs -f juicefs
docker compose down            # matikan — data & metadata aman
```

> ⚠️ **Jangan `docker compose down -v`.** Itu menghapus volume Redis, dan
> seluruh file system hilang meski object masih utuh di R2.

Masuk ke container:

```bash
docker compose exec juicefs bash
META="redis://redis:6379/2"

juicefs status $META            # info volume & sesi aktif
juicefs profile /mnt/jfs        # operasi FUSE real-time — alat debug terbaik
juicefs bench /mnt/jfs -p 4     # benchmark
juicefs info /mnt/jfs/berkas    # lihat chunk/slice/block
juicefs warmup /mnt/jfs/data    # paksa isi cache
juicefs gc $META --compact      # kompaksi slice terfragmentasi
```

Menyalin berkas dari macOS tanpa lewat Finder:

```bash
cp ~/Downloads/berkas.zip shared/
docker compose exec juicefs cp /shared/berkas.zip /mnt/jfs/
```

Memantau pertumbuhan metadata:

```bash
docker compose exec redis redis-cli info memory | grep used_memory_human
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
| `BUFFER_SIZE` | `300` | tampungan tulis, MiB — jangan diturunkan tanpa mengukur |
| `MAX_DOWNLOADS` | `32` | konkurensi baca (default JuiceFS 200) |
| `MAX_UPLOADS` | `20` | konkurensi tulis; naikkan untuk berkas multi-GB |
| `TRASH_DAYS` | `1` | masa simpan berkas terhapus |
| `BACKUP_META` | `1h` | interval backup otomatis ke R2; `0` mematikan |
| `BACKUP_ON_STOP` | `true` | dump metadata saat container berhenti |
| `KEEP_SHUTDOWN_DUMPS` | `5` | rotasi dump tersebut |
| `ENABLE_SMB` | `true` | server Samba |
| `ENABLE_WEBDAV` | `false` | server WebDAV (cadangan) |
| `SMB_USER` / `SMB_PASSWORD` | `jfs` / — | **wajib diisi** |
| `WEBDAV_USER` / `WEBDAV_PASSWORD` | `jfs` / — | dipakai kalau WebDAV menyala |
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

## Trash

Berkas terhapus mampir ke `.trash` selama `TRASH_DAYS`, berlaku untuk **semua
jalur** — Finder, terminal, aplikasi mana pun.

Trash sengaja disembunyikan dari Finder, jadi pemulihan lewat container:

```bash
docker compose exec juicefs find /mnt/jfs/.trash -type f
docker compose exec juicefs mv /mnt/jfs/.trash/<...>/<berkas> /mnt/jfs/
```

Format nama: `<inode-induk>-<inode>-<nama-asli>`. Berkas di trash **tetap
memakan storage R2** selama masa simpan.

## Backup

Tiga lapis, dua di antaranya otomatis:

| Lapis | Kapan | Ke mana |
|---|---|---|
| 1 | tiap jam | R2, prefix `<volume>/meta/` |
| 2 | tiap `compose down` / `stop` | `dumps/shutdown-*.json.gz` |
| 3 | manual: `./backup-meta.sh` | `dumps/meta-*.json.gz` |

Memulihkan: [`dumps/CARA-RESTORE.md`](dumps/CARA-RESTORE.md).
Rincian lengkap: [Backup metadata](docs/backup.md).

## Struktur project

| Berkas | Isi |
|---|---|
| `docker-compose.yml` | service, volume, environment |
| `Dockerfile` | image `juicedata/mount` + Samba |
| `entrypoint.sh` | logika startup dan shutdown |
| `smb.conf` | konfigurasi Samba untuk macOS |
| `backup-meta.sh` | dump metadata + rotasi |
| `docs/` | dokumentasi lanjutan |
| `launchd/` | template penjadwalan backup (opsional) |
| `dumps/` | tujuan dump metadata |
| `shared/` | jembatan berkas macOS ↔ container |

Logika startup ada di `entrypoint.sh`, bukan inline di compose — bisa
di-`shellcheck` dan bebas dari kerepotan `$$` escaping. Setelah mengeditnya,
jalankan `docker compose up -d --build juicefs`.

## Troubleshooting

**Finder gagal konek, "server may not exist"**
Pakai `smb://jfs-client.orb.local/jfs`, bukan `localhost`. Kalau masih gagal,
hapus entri `localhost` bertipe *network password* di Keychain Access.

**Finder gagal padahal `mount_smbfs` berhasil**
macOS menolak me-mount share SMB yang sama dua kali. Cek `mount | grep smbfs`
lalu `umount` yang tidak dipakai.

**Muncul berkas `._namafile` di storage**
`--enable-xattr` tidak aktif — [penjelasannya](docs/temuan-teknis.md#2---enable-xattr-wajib-kalau-memakai-samba).

**`/mnt/jfs` kosong dari macOS**
Normal — [kenapa](docs/temuan-teknis.md#4-mntjfs-akan-terlihat-kosong-dari-macos).

**Container gagal start**
`docker compose logs juicefs`. Kalau `.env` kurang lengkap, compose berhenti
dengan pesan variabel mana yang kosong.

**Tulis dari Finder terasa lambat**
Wajar — bottleneck-nya R2, bukan protokol. Untuk berkas besar, salin lewat
`shared/`. Lihat [Performa](docs/performa-dan-biaya.md#performa).

## Dokumentasi lanjutan

| Dokumen | Isi |
|---|---|
| [Temuan teknis](docs/temuan-teknis.md) | dokumentasi JuiceFS yang usang soal R2, jebakan `--enable-xattr`, `smb://localhost` yang diblokir, FUSE yang tak terlihat dari macOS |
| [Backup metadata](docs/backup.md) | tiga lapis backup, prosedur pemulihan, format dump |
| [Keamanan](docs/keamanan.md) | paparan port, kredensial, pengerasan |
| [Performa dan biaya](docs/performa-dan-biaya.md) | angka pengukuran, tarif R2 vs S3, batasan penskalaan |
| [Mount native lewat macFUSE](docs/mount-native-macfuse.md) | jalur alternatif tanpa Samba — kenapa butuh kext, prosedur Recovery Mode, jebakan kext yang "hilang" tiap reboot |
| [Laporan migrasi ke native](docs/laporan-migrasi-native.md) | daftar perubahan 29 Juli 2026: apa yang disentuh di sistem, apa di repo, apa yang tidak, dan cara membatalkan |

## Rujukan

- [Dokumentasi JuiceFS](https://juicefs.com/docs/community/introduction/)
- [Arsitektur JuiceFS](https://juicefs.com/docs/community/architecture)
- [Cloudflare R2](https://developers.cloudflare.com/r2/)
- [OrbStack](https://orbstack.dev)
