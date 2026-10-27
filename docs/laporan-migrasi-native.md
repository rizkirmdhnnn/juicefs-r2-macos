# Laporan migrasi ke native

[← kembali ke README](../README.md)

Catatan apa saja yang berubah pada **29 Juli 2026**, saat lab ini dipindahkan
dari Docker ke native. Ditulis untuk dibaca ulang nanti — bukan panduan, tapi
daftar perubahan.

Panduan teknis dan angka pengukurannya ada di
[Mount native lewat macFUSE](mount-native-macfuse.md).

---

## Satu paragraf

Dulu semuanya jalan di dalam Docker: Redis, JuiceFS, dan Samba. Finder
menyambung lewat SMB. Sekarang ketiganya tidak dipakai lagi — Redis jalan
langsung dari Homebrew, JuiceFS ter-mount langsung di macOS lewat macFUSE, dan
Finder membaca volumenya sebagai disk biasa. **Data di R2 tidak disentuh sama
sekali**; yang pindah hanya metadata, dari Redis di container ke Redis di
Homebrew.

```
SEBELUM                                  SESUDAH

Finder                                   Finder
  │ SMB                                    │
  ▼                                        ▼
Samba ──► JuiceFS ──► R2                 macFUSE ──► JuiceFS ──► R2
              │                                          │
              ▼                                          ▼
        Redis (container)                        Redis (Homebrew)

semua di dalam Docker                    tidak ada Docker
```

---

## Yang berubah di sistem (di luar folder repo)

| Apa | Detail | Cara membatalkan |
|---|---|---|
| Redis dipasang | `brew install redis` (8.8.1) | `brew uninstall redis` |
| Redis autostart | `brew services start redis` | `brew services stop redis` |
| Config Redis diedit | `/opt/homebrew/etc/redis.conf` — ditambah `appendonly yes` + `maxmemory-policy noeviction`, ditandai blok komentar `--- juicefs-lab ---` | hapus blok itu |
| Agent mount | `~/Library/LaunchAgents/com.juicefs.lab.mount.plist` | `launchctl unload` + hapus |
| Agent backup | `~/Library/LaunchAgents/com.juicefs.lab.backup.plist` | `launchctl unload` + hapus |
| Folder mount | `~/jfs` | hapus setelah unmount |
| Cache lokal | `~/Library/Caches/JuiceFS` (~166 MB, boleh dihapus kapan saja) | hapus |
| Container | `docker compose down` — container hilang, **volume tetap ada** | `docker compose up -d` |

Kenapa dua baris config Redis itu penting:

- **`appendonly yes`** — tanpa ini Redis cuma menyimpan snapshot berkala.
  Perubahan sejak snapshot terakhir hilang kalau Mac mati mendadak. Container
  lama sudah memakai ini (`redis-server --appendonly yes`), jadi ini sekadar
  menyamakan.
- **`maxmemory-policy noeviction`** — kalau Redis boleh membuang key saat memori
  penuh, metadata ikut terbuang, dan data di R2 berubah jadi blok anonim yang
  tidak bisa dirangkai kembali.

---

## Yang berubah di dalam repo

### Berkas baru

| Berkas | Isi |
|---|---|
| `mount-native.sh` | skrip mount native; menunggu Redis siap, lalu `juicefs mount` di foreground |
| `launchd/com.juicefs.lab.mount.plist` | template agent mount (yang terpasang adalah salinannya di `~/Library/LaunchAgents/`) |
| `docs/mount-native-macfuse.md` | panduan lengkap + semua hasil pengukuran |
| `docs/laporan-migrasi-native.md` | berkas ini |

### Berkas yang diubah

| Berkas | Perubahannya | Kenapa |
|---|---|---|
| `backup-meta.sh` | `docker compose exec` → `juicefs dump` langsung; cek container diganti cek Redis; `PATH` Homebrew ditambahkan | begitu container mati, backup gagal diam-diam |
| `.env` | tambah `META_URL_NATIVE=redis://127.0.0.1:6379/2` | `META_URL` lama menunjuk host `redis` yang hanya ada di jaringan Docker |
| `.env.example` | sama, plus penjelasannya | |
| `launchd/README.md` | ditulis ulang: dua agent, keduanya terpasang | dulu isinya cuma satu template yang tidak dipasang |
| `docs/backup.md` | catatan: lapis backup ke-2 hilang di jalur native | |
| `docs/performa-dan-biaya.md` | tambah hasil ukur native vs SMB + catatan bias page cache | |
| `README.md` | catatan di atas bahwa ada dua jalur | |

### Yang TIDAK disentuh

Supaya tenang — semua ini utuh, tidak diubah sebaris pun:

- **Bucket R2 dan seluruh isinya.** Tidak ada berkas yang dipindah atau dihapus.
- **Kredensial di `.env`** (`R2_*`, `SMB_*`, `WEBDAV_*`).
- **`docker-compose.yml`**, `Dockerfile` — jalur Docker masih utuh dan bisa
  dihidupkan lagi.
- **Volume Docker** `juicefs-lab_redis-data` dan `juicefs-lab_jfs-cache`
  sengaja tidak dihapus.

> **Catatan jujur:** `entrypoint.sh`, `smb.conf`, `docs/keamanan.md`, dan
> `docs/temuan-teknis.md` juga muncul sebagai berubah di `git status` — tapi itu
> **bukan** hasil kerja saya. Keempatnya sudah dalam keadaan berubah sejak awal
> sesi ini. `README.md` juga sudah berubah sebelumnya; saya hanya menambahkan
> satu blok catatan di bagian atas.
>
> Satu hal lagi: `docs/mount-native-macfuse.md` sudah terdaftar sebagai berkas
> untracked di `git status` awal sesi. Kalau sebelumnya kamu sudah menulis
> sesuatu di sana, isinya kemungkinan tertimpa oleh dokumen yang saya buat.
> Berkas itu tidak pernah masuk git, jadi tidak bisa dipulihkan dari history.

---

## Bagaimana metadata dipindahkan

Metadata adalah titik kegagalan tunggal, jadi urutannya dijaga: **backup →
hentikan semua penulis → pindah → verifikasi → baru potong.**

1. Backup pra-migrasi → `dumps/pra-migrasi-20260729-190416.json.gz`
2. Catat baseline: **4.946 entri** + checksum tiga berkas
3. Hentikan penulis: `juicefs umount ~/jfs` lalu `docker compose stop juicefs`
   — dump yang diambil selagi ada yang menulis menghasilkan metadata tidak konsisten
4. `juicefs dump` (Redis container) → `juicefs load` (Redis brew)
5. `juicefs config --secret-key` — **wajib**, karena `dump` selalu membuang
   secret key demi keamanan. Tanpa langkah ini volume ter-mount tapi setiap
   pembacaan gagal, dan pesan errornya tidak menyebut kredensial sama sekali
6. Verifikasi dengan mount **read-only** dari metadata baru
7. Baru `docker compose down`

**Hasil verifikasi:** 4.946 entri sama persis, ketiga checksum identik.

Setelahnya jumlah entri terbaca 4.952. Selisih 6 itu sudah ditelusuri: berkas
penanda `.metadata_never_index` yang saya buat, plus berkas uji saya yang masuk
`.trash`. Bukan anomali.

---

## Finder tampil, Spotlight tidak mengindeks

Dua permintaan yang saling bertentangan: opsi `-o local` membuat Finder
memperlakukan volume sebagai disk (muncul di sidebar) — tapi justru volume lokal
yang diindeks Spotlight. Mengindeks file system di atas object storage berarti
`mds` membaca ulang semua block dari R2, jadi tagihan operasi tanpa kamu minta.

Yang dipakai: `-o local` untuk Finder, plus berkas penanda `.metadata_never_index`
di root volume untuk menolak indexer.

`mdutil -i off ~/jfs` **tidak bisa** dipakai — karena mount point ada di dalam
home, `mdutil` menerjemahkannya ke `/System/Volumes/Data/...` lalu menolak
dengan `unknown indexing state`.

Diuji, bukan diasumsikan:

| Uji | Hasil |
|---|---|
| Berkas bertoken unik di `~/jfs`, tunggu 45 detik | `mdfind` tidak menemukan ✅ |
| Kontrol: token serupa di `~/Documents`, tunggu 40 detik | `mdfind` **menemukan** |

Kontrol itu yang membuat hasilnya berarti. Tanpa pembanding, "tidak ditemukan"
bisa saja cuma berarti indexer-nya sedang lambat.

---

## Perbaikan setelah laporan ini ditulis

**29 Juli 2026, sore — error `-8062` saat menyalin folder dari Finder.**

Penyebabnya opsi mount `noappledouble` yang saya pasang di `mount-native.sh`.
Opsi itu ternyata tidak cuma memblokir berkas `._*`, tapi juga `.DS_Store` —
dan Finder membuat `.DS_Store` di hampir setiap folder yang disentuhnya.

Sudah dicabut dari `mount-native.sh`, volume sudah di-mount ulang. `--enable-xattr`
sendiri sudah cukup mencegah berkas `._*` (terbukti: 0 berkas `._*` setelah
menyalin 187 berkas ber-xattr).

Rinciannya di [temuan #7](temuan-teknis.md#7--o-noappledouble-membuat-salinan-finder-gagal-8062).

---

## Yang berkurang

**Lapis backup kedua hilang.** Dulu setiap `docker compose down`/`stop`,
`entrypoint.sh` membuat dump metadata otomatis. Di jalur native tidak ada
container yang berhenti, jadi tidak ada pemicunya, dan tidak ada penggantinya.

Sebagai kompensasi, agent backup harian (`com.juicefs.lab.backup`, tiap hari
12:00) sekarang **dipasang** — selama ini sengaja tidak dipasang karena dump
saat container berhenti sudah menutupi. Kalau kamu lebih suka lapis itu kosong:

```bash
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
```

**Samba dan WebDAV juga ikut mati** karena keduanya hidup di dalam container.
Kalau suatu saat butuh akses dari perangkat lain di jaringan, jalur Docker
harus dihidupkan lagi.

---

## Apa yang terjadi saat Mac di-restart

Semuanya otomatis. Tidak ada yang perlu dijalankan manual.

**Saat dimatikan:** launchd mengirim SIGTERM ke proses `juicefs`, yang mem-flush
buffer tulis lalu melepas volume.

Diuji: salin berkas 150 MB, lalu SIGTERM **tepat** setelah `cp` selesai —
kondisi paling rawan, karena aplikasi mengira berkasnya sudah tersimpan padahal
sebagian mungkin masih di buffer. Hasilnya proses berhenti dalam 2 detik dan
checksum berkas **identik**. Data tidak hilang.

**Saat login:** tiga hal berurutan tanpa dijamin urutannya oleh launchd —

| Komponen | Pemicu |
|---|---|
| kext macFUSE | dimuat sesuai permintaan, saat mount pertama |
| Redis | `homebrew.mxcl.redis` (brew services) |
| Mount | `com.juicefs.lab.mount`, `RunAtLoad` |

Kalau agent mount menang duluan, ia **menunggu** Redis sampai 60 detik.

Diuji dengan sengaja membalik urutannya: Redis dimatikan, agent mount
dihidupkan lebih dulu. Setelah 8 detik volume belum ter-mount dan tidak ada
proses yang berputar-putar — memang sedang menunggu. Begitu Redis dinyalakan,
volume ter-mount **4 detik** kemudian.

Kalau Redis butuh lebih dari 60 detik, skrip menyerah, lalu launchd
menjalankannya lagi 30 detik kemudian (`ThrottleInterval`) — jadi tetap sembuh
sendiri, hanya lebih lambat.

**Yang tetap bertahan lintas restart:** kebijakan boot kext
(`spctl kext-consent status` → `ENABLED`), penanda `.metadata_never_index` di
volume, dan kedua LaunchAgent.

> Keduanya **LaunchAgent tingkat user**, bukan daemon sistem. Artinya tidak ada
> yang jalan sebelum kamu login — kalau Mac menyala tapi berhenti di layar
> login, volume belum ter-mount. Untuk pemakaian desktop biasa ini tidak masalah.

---

## Kalau Mac dimatikan paksa

Diuji dengan `SIGKILL` ke proses `juicefs` — tidak ada kesempatan flush sama
sekali, pendekatan terdekat ke listrik putus.

| Skenario | Hasil |
|---|---|
| Berkas 150 MB, `cp` **sudah selesai**, lalu dibunuh | checksum **identik** — aman |
| Berkas 1 GB, dibunuh **saat menyalin** (detik ke-8) | terpotong di 507 MB, `cp` menerima `Input/output error` |
| Bagian yang tersisa dari berkas terpotong itu | **byte-per-byte cocok** dengan 507 MB pertama sumber — terpotong rapi, tanpa lubang |

Dua hal penting dari situ:

1. **Begitu aplikasi selesai menyimpan, datanya sudah di R2.** JuiceFS mem-flush
   saat berkas ditutup, bukan menahannya di buffer sampai sempat.
2. **Kegagalan tidak disembunyikan.** Aplikasi menerima error, bukan mengira
   berhasil padahal berkasnya bolong.

### Yang tetap perlu diperhatikan

**Objek yatim di R2.** Unggahan yang terputus meninggalkan blok yang tidak
dirujuk metadata mana pun — tidak terlihat dari Finder, tapi tetap ditagih.
Setelah uji di atas, terukur **21 objek, 64 MB**. Cara memeriksa dan
membersihkan:

```bash
juicefs fsck redis://127.0.0.1:6379/2      # blok hilang?
juicefs gc   redis://127.0.0.1:6379/2      # objek yatim? (hanya melihat)
juicefs gc --delete redis://127.0.0.1:6379/2
```

Layak dijalankan sesekali, terutama setelah mati paksa.

**Metadata bisa mundur ~1 detik.** Redis memakai `appendfsync everysec`, jadi
perubahan metadata pada detik terakhir sebelum listrik putus bisa hilang.
`aof-load-truncated yes` membuat Redis memperbaiki catatan yang setengah tertulis
saat start, bukan menolak jalan.

**Batas ujinya.** `SIGKILL` ke satu proses bukan listrik putus sungguhan — pada
mati paksa asli, page cache macOS dan buffer AOF Redis ikut hilang. Tiga uji di
atas tidak menemukan kehilangan data, tapi tiga uji bukan bukti bahwa hal itu
mustahil.

---

## Cara memeriksa semuanya sehat

```bash
mount | grep macfuse                  # volume ter-mount?
brew services list | grep redis       # Redis jalan?
launchctl list | grep juicefs         # dua agent terdaftar?
tail dumps/backup.log                 # backup harian terakhir kapan?
tail dumps/mount.log                  # ada error mount?
```

Yang wajar terlihat:

```
JuiceFS:mydiskjfs on /Users/rizkirmdhn/jfs (macfuse, local, ...)
redis   started   rizkirmdhn  ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
-       0         com.juicefs.lab.backup
42566   0         com.juicefs.lab.mount
```

---

## Kalau bermasalah

| Gejala | Kemungkinan | Tindakan |
|---|---|---|
| `~/jfs` kosong / hilang dari Finder | agent mati atau Redis belum siap | `tail ~/.local/share/juicefs-lab/dumps/mount.log`, lalu `launchctl kickstart -k gui/$(id -u)/com.juicefs.lab.mount` |
| `launchctl list` menunjukkan exit **127** | plist menunjuk berkas yang tidak ada — biasanya karena folder repo dipindah | jalankan ulang `./launchd/install.sh` |
| `connection refused` | Redis tidak jalan | `brew services restart redis` |
| Volume ter-mount tapi berkas gagal dibaca | secret key belum terpasang | `juicefs config redis://127.0.0.1:6379/2 --secret-key "$R2_SECRET_KEY"` |
| Muncul berkas `._namafile` | `--enable-xattr` tidak aktif | cek flag di `mount-native.sh` |
| `kmutil showloaded` tidak menampilkan fuse | **normal** kalau belum ada mount | kext dimuat sesuai permintaan, lihat [jebakannya](mount-native-macfuse.md#jebakan-kext-hilang-setiap-reboot-) |

---

## Membatalkan seluruhnya

Urutannya penting. Jangan sampai dua client menulis ke bucket yang sama dengan
metadata berbeda — itu bikin objek yatim.

```bash
# 1. Matikan jalur native lebih dulu
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.mount.plist
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
juicefs umount ~/jfs

# 2. Pindahkan metadata BALIK — jangan pakai salinan lama di volume Docker,
#    isinya membeku di waktu migrasi dan tidak memuat perubahan sesudahnya
docker compose up -d redis
juicefs dump redis://127.0.0.1:6379/2 balik.json
docker compose exec -T redis redis-cli -n 2 flushdb
juicefs load redis://127.0.0.1:6380/2 balik.json
juicefs config redis://127.0.0.1:6380/2 --secret-key "$R2_SECRET_KEY"

# 3. Hidupkan lagi jalur Docker
docker compose up -d

# 4. Bersihkan sisa jalur native
brew services stop redis
rm ~/Library/LaunchAgents/com.juicefs.lab.{mount,backup}.plist
```

macFUSE sendiri boleh dibiarkan terpasang — tidak mengganggu apa pun kalau tidak
dipakai. Kalau mau bersih total: `brew uninstall --cask macfuse`, lalu kembalikan
security policy ke **Full Security** lewat Recovery Mode.
