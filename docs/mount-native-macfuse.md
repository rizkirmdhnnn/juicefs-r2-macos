# Mount native lewat macFUSE

[← kembali ke README](../README.md)

Jalur alternatif: JuiceFS ter-mount **langsung di macOS** sebagai FUSE mount,
bukan lewat Samba. Tidak ada protokol jaringan di tengah, tidak ada container
yang memegang mount-nya.

> **Status: ini jalur yang sekarang berjalan.** Sejak 29 Juli 2026, seluruh
> tumpukan pindah ke native — Redis lewat `brew services`, JuiceFS ter-mount
> langsung di macOS lewat macFUSE 5.3.3 (macOS 27.0, Apple Silicon). Docker
> tidak lagi dipakai untuk operasi harian; stack-nya tetap ada sebagai jalan
> mundur. Prosedurnya di [Migrasi penuh](#migrasi-penuh-docker--native-).
>
> Perlu diketahui sebelum ikut memindahkan: mount native **tidak lebih cepat**
> untuk berkas besar ([datanya](#performa-native-vs-smb-)). Yang benar-benar
> berubah adalah metadata (1,37× lebih cepat), mount point bebas, dan lepas
> dari jebakan-jebakan SMB.

---

## Beda dengan jalur SMB

```
JALUR SMB (default repo)              JALUR NATIVE (dokumen ini)

Finder                                Finder
  │ SMB                                 │ syscall VFS
  ▼                                      ▼
Samba (container)                     kext macFUSE
  │                                      │
  ▼                                      ▼
JuiceFS (container) ──► R2            JuiceFS (proses di macOS) ──► R2
  │                                      │
  └── metadata ──► Redis                 └── metadata ──► Redis
                                              127.0.0.1:6380
```

| | SMB | Native macFUSE |
|---|---|---|
| Kernel extension | tidak | **ya** |
| Reboot untuk pasang | tidak | **dua kali** (Apple Silicon) |
| Security policy | tidak disentuh | **Reduced Security** |
| Yang bicara ke R2 | proses di container | proses di macOS |
| Cache baca | volume `jfs-cache` | direktori di disk Mac |
| Mount point | `/Volumes/jfs` | bebas, mis. `~/jfs` |
| Jebakan `smb://localhost` | ada | tidak relevan |
| Kalau OrbStack mati | share hilang | mount jadi zombie sampai Redis kembali |

Yang tidak berubah: Redis dan bucket R2 tetap satu-satunya sumber kebenaran.
Dua client yang mount volume sama **memang desain JuiceFS** — bukan konflik.

---

## Kondisi mesin saat dokumen ditulis ✅

| Cek | Hasil | Perintah |
|---|---|---|
| macOS | 27.0 (26A5388g), arm64 | `sw_vers; uname -m` |
| SIP | enabled | `csrutil status` |
| macFUSE | belum terpasang | `ls /Library/Filesystems` |
| kext FUSE termuat | tidak ada | `kmutil showloaded --list-only \| grep -i fuse` |
| JuiceFS | 1.4.0+2026-07-06 (Homebrew) | `juicefs version` |
| Metadata dari Mac | terjangkau, ping 0,4 ms | `juicefs status redis://127.0.0.1:6380/2` |

macFUSE 5.3.3 (rilis 4 Juli 2026) mensyaratkan **macOS 12 atau lebih baru**;
dukungan macOS 27 masuk sejak 5.3.1. Jadi versi OS bukan penghalang.

---

## Temuan: JuiceFS tidak bisa memakai backend FSKit ✅

macFUSE 5 punya dua backend, dan yang kedua seharusnya menghapus seluruh
kerepotan Recovery Mode:

| | Kernel (VFS) | FSKit |
|---|---|---|
| Butuh kext | ya | **tidak** |
| Recovery Mode di Apple Silicon | **wajib** | tidak |
| Performa I/O | lebih tinggi | di bawah kernel backend |
| Mount point | bebas | terbatas di `/Volumes` |
| Cara memilih | default | `-o backend=fskit` |

Tapi FSKit hanya tersedia bagi file system yang berjalan **melalui `libfuse`**.
JuiceFS tidak begitu:

```bash
otool -L "$(which juicefs)"
# → hanya libresolv, CoreFoundation, Security, IOKit, CoreServices, libSystem.
#   Tidak ada libfuse sama sekali.

strings -a "$(which juicefs)" | grep -o -E 'OSXFUSE_[A-Z_]*|mount_macfuse|osxfusefs' | sort -u
# → OSXFUSE_CALL_BY_LIB
#   OSXFUSE_DAEMON_PATH
#   mount_macfuse
#   osxfusefs
```

Binary-nya memanggil helper `/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse`
dan device `/dev/macfuse*` secara langsung — pola library `go-fuse`, bukan
`libfuse`. **Konsekuensinya backend kernel wajib**, dan di Apple Silicon itu
berarti Reduced Security plus dua reboot. Tidak ada jalan pintas.

> Kalau suatu saat JuiceFS pindah ke `libfuse`, cek ulang temuan ini — seluruh
> Langkah 1 di bawah jadi tidak perlu.

---

## Langkah 1 — Reduced Security di Recovery Mode

Harus manual, tidak bisa di-otomasi dari terminal.

1. Matikan Mac sepenuhnya (menu Apple → Shut Down).
2. **Tahan tombol power** sampai muncul "Loading startup options" →
   **Options** → **Continue**.
3. Pilih user admin, masukkan password.
4. Menu bar: **Utilities → Startup Security Utility**.
5. Pilih disk sistem → **Security Policy…**
6. Pilih **Reduced Security**, lalu centang
   **"Allow user management of kernel extensions from identified developers"**.
7. **OK** → autentikasi → **Restart**.

Yang berubah hanya kebijakan boot soal kext pihak ketiga. **SIP tetap menyala**
dan FileVault tidak terpengaruh. Bisa dikembalikan ke Full Security kapan saja
lewat menu yang sama.

macFUSE tidak meminta Gatekeeper atau SIP dimatikan — semua rilisnya dinotarisasi
Apple.

---

## Langkah 2 — Pasang macFUSE

```bash
brew install --cask macfuse
```

Alternatif: unduh `macfuse-5.3.3.dmg` dari [halaman rilis](https://github.com/macfuse/macfuse/releases).

Setelah installer selesai, macOS memblokir kext-nya:

1. **System Settings → Privacy & Security**, scroll ke bawah.
2. "System software from developer **Benjamin Fleischer** was blocked from
   loading" → **Allow**.
3. Password → **Restart** (reboot kedua).

---

## Langkah 3 — Verifikasi macFUSE terpasang

**Jangan pakai `kmutil showloaded` untuk ini.** Alasannya di bagian berikutnya —
itu jebakan yang memakan waktu paling banyak di sini.

Tiga cek yang benar:

```bash
ls /Library/Filesystems/macfuse.fs                 # bundle terpasang
pkgutil --pkgs | grep -i fuse                      # paket terdaftar di sistem
spctl kext-consent status                          # harus: ENABLED
```

Hasil di mesin ini ✅:

```
/Library/Filesystems/macfuse.fs/Contents/Extensions/ → 12/  14/  26/
                                                       13→12  15→14  27→26
io.macfuse.installer.components.core
io.macfuse.installer.components.preferencepane
Kernel Extension User Consent: ENABLED
```

`27 → 26` adalah symlink: macFUSE memakai kext build macOS 26 untuk macOS 27.

`spctl kext-consent status: ENABLED` adalah bukti Langkah 1 tersimpan permanen.
Kalau di sini tertulis `DISABLED`, Recovery Mode belum berhasil — ulangi
Langkah 1, jangan menginstal ulang macFUSE.

---

## Jebakan: kext "hilang" setiap reboot ✅

**Gejala:** sesaat setelah instalasi, `kmutil showloaded --list-only | grep -i fuse`
memunculkan `io.macfuse.filesystems.macfuse`. Setelah restart, hilang — seolah
macFUSE tercopot dan harus dipasang ulang.

**Bukan tercopot.** Kext macFUSE bersifat **demand-loaded**: kernel baru
memuatnya saat `mount_macfuse` dipanggil untuk mount FUSE pertama, dan
melepasnya lagi kalau tidak ada volume yang aktif. Setelah reboot tanpa mount,
daftar kext yang termuat memang kosong. Itu kondisi normal, bukan kegagalan.

`kmutil showloaded` menjawab *"apa yang sedang berjalan di kernel"*, bukan
*"apa yang terpasang di disk"*. Untuk pertanyaan kedua, pakai tiga perintah di
Langkah 3.

Bukti demand-load, diukur berurutan di mesin ini:

| Kondisi | `kmutil showloaded \| grep fuse` | `/dev/macfuse*` |
|---|---|---|
| Setelah reboot, belum mount | kosong | tidak ada |
| Setelah `juicefs mount` | `io.macfuse.filesystems.macfuse.25 (5.3.3)` | `macfuse0`, `macfuse1`, … |

Menginstal ulang macFUSE karena gejala ini hanya membuang waktu — dan berisiko
memicu prompt approval Privacy & Security lagi tanpa alasan.

> **Aturan praktis:** cek terpasang lewat `ls /Library/Filesystems/macfuse.fs`.
> Cek termuat hanya *setelah* ada mount aktif.

---

## Langkah 4 — Mount

Kredensial R2 **tidak perlu ditulis ulang**. JuiceFS menyimpannya di metadata,
jadi client Mac membacanya dari Redis — `.env` tidak dibaca sama sekali di
jalur ini.

Syaratnya Redis harus hidup dulu. Setelah reboot, OrbStack tidak otomatis
menyalakan container:

```bash
docker info >/dev/null 2>&1 || open -a OrbStack
docker compose up -d
juicefs status redis://127.0.0.1:6380/2 >/dev/null && echo "meta siap"
```

Kalau dilewati, mount gagal dengan `dial tcp 127.0.0.1:6380: connect: connection refused`.

```bash
mkdir -p ~/jfs

juicefs mount redis://127.0.0.1:6380/2 ~/jfs \
  --background \
  --cache-dir ~/Library/Caches/JuiceFS \
  --cache-size 10240 \
  --buffer-size 300 \
  --max-downloads 32 \
  --max-uploads 20 \
  --enable-xattr \
  --backup-meta 0 \
  -o volname=JuiceFS
```

> Versi awal dokumen ini menganjurkan `-o noappledouble`. **Jangan dipakai** —
> opsi itu ikut memblokir `.DS_Store` dan membuat penyalinan folder dari Finder
> gagal dengan `error code -8062`. Lihat
> [temuan #7](temuan-teknis.md#7--o-noappledouble-membuat-salinan-finder-gagal-8062).

| Flag | Alasan |
|---|---|
| `--enable-xattr` | tanpa ini Finder menulis berkas `._*` **sungguhan** ke R2 — [temuan #2](temuan-teknis.md#2---enable-xattr-wajib-kalau-memakai-samba) |
| `--backup-meta 0` | client container sudah dump tiap jam; dua client yang sama-sama backup cuma menggandakan operasi R2 |
| `--cache-dir` | terpisah dari volume `jfs-cache` milik container, supaya tidak rebutan |
| `--cache-size 10240` | MiB, menyamai `CACHE_SIZE` di `.env` |
| `--buffer-size 300` | ikut hasil pengukuran di [Performa](performa-dan-biaya.md) |
| `--max-downloads 32` | idem — 200 (default) boros RAM tanpa untung di koneksi rumahan |
| ~~`-o noappledouble`~~ | **dicabut** — memblokir `.DS_Store` juga, Finder gagal dengan -8062. `--enable-xattr` sendiri sudah cukup mencegah berkas `._*` |
| `-o volname=` | nama volume yang tampil di Finder |

**`-o` hanya boleh muncul sekali.** Flag-nya string biasa, bukan slice — kalau
ditulis `-o a -o b`, yang belakangan menimpa yang depan tanpa peringatan.
Pisahkan dengan koma.

Log ada di `~/.juicefs/juicefs.log` (default saat `--background`).

---

## Langkah 5 — Uji ✅

Semua di bawah ini sudah dijalankan dan lolos.

```bash
mount | grep macfuse
# JuiceFS:mydiskjfs on /Users/rizkirmdhn/jfs (macfuse, nodev, nosuid, synchronous,
#                                            mounted by rizkirmdhn)

df -h ~/jfs
# JuiceFS:mydiskjfs  1.0Pi  668Mi  1.0Pi  1%  /Users/rizkirmdhn/jfs
```

**Tulis dari Mac, baca dari container** — bukti keduanya volume yang sama:

```bash
echo "halo dari macFUSE" > ~/jfs/dari-mac.txt
docker compose exec -T juicefs cat /mnt/jfs/dari-mac.txt     # → halo dari macFUSE
```

**xattr benar-benar aktif** (bukan sekadar flag diterima):

```bash
xattr -w user.uji nilai ~/jfs/dari-mac.txt
xattr -p user.uji ~/jfs/dari-mac.txt      # → nilai
ls -a ~/jfs | grep '^\._'                 # → nihil, tidak ada AppleDouble
```

**Dua sesi hidup berdampingan:**

```bash
juicefs status redis://127.0.0.1:6380/2 | grep -E '"MountPoint"|"HostName"'
# "HostName": "Achmads-MacBook-Air.local"   "MountPoint": "/Users/rizkirmdhn/jfs"
# "HostName": "f0a17b7a7be3"                "MountPoint": "/mnt/jfs"
```

---

## Langkah 6 — Unmount

```bash
juicefs umount ~/jfs
umount -f ~/jfs        # kalau ngambek
```

**Selalu unmount sebelum mematikan OrbStack.** Kalau Redis hilang lebih dulu,
mount-nya jadi zombie: setiap `ls` menggantung sampai metadata kembali atau
mount dipaksa lepas.

---

## Performa: native vs SMB ✅

**Kesimpulan lebih dulu: mount native tidak lebih cepat.** Median SMB justru
sedikit di atasnya, dan SMB jauh lebih konsisten. Bottleneck-nya link ke R2,
bukan lapisan protokol.

### Metode

- Berkas 166,3 MiB yang sudah ada di volume, `dd bs=1m`
- **9 sampel per jalur**, dijalankan berselang-seling (native → SMB → native →
  …) supaya fluktuasi jaringan tidak menguntungkan satu pihak
- Cold = cache client dikosongkan sebelum **tiap** sampel:
  - native: `find ~/Library/Caches/JuiceFS -type d -name raw -exec rm -rf {} +` lalu remount
  - SMB: `rm -rf /var/jfsCache/*/raw/*` di container lalu `docker compose restart juicefs`
- Flag kedua client diverifikasi identik: `--buffer-size 300`,
  `--max-downloads 32`, `--max-uploads 20`, `--enable-xattr`

### Hasil baca dingin

| | Native macFUSE | SMB |
|---|---|---|
| **Median** | 15,0 MiB/s | **16,4 MiB/s** |
| Rata-rata | 14,0 MiB/s | 16,5 MiB/s |
| Terburuk | **8,1 MiB/s** | 14,5 MiB/s |
| Terbaik | **19,6 MiB/s** | 18,3 MiB/s |
| Sebaran (maks÷min) | **2,41×** | 1,26× |
| Simpangan baku | 4,3 | **1,3** |

Waktu tiap sampel, diurutkan (detik):

```
native :  8,5   9,0   9,6  10,5  11,1  13,0  15,1  20,4  20,5
SMB    :  9,1   9,3   9,4   9,9  10,1  10,3  10,4  11,4  11,4
```

### Bacaannya

1. **Tidak ada keuntungan throughput.** Native memang mencatat sampel tercepat
   (19,6 MiB/s), tapi juga dua sampel terlambat — dan medianya kalah. Samba
   menambah lapisan protokol yang ongkosnya tenggelam di balik waktu tunggu R2.
2. **SMB lebih bisa diprediksi.** Sembilan sampel SMB masuk rentang 14,5–18,3
   MiB/s. Native dua kali jatuh ke 8,1 MiB/s — dan keduanya persis 20,4 detik,
   bukan sebaran acak.
3. **Pencilan native belum dijelaskan.** Bukan perbedaan flag (sudah diverifikasi
   identik), bukan urutan pengujian (muncul di ronde 1 dan 4). Satu pengamatan
   lain yang mungkin berkaitan: membaca <5 detik setelah mount pernah
   menghasilkan 21,9 MiB/s, seolah ada fase pemanasan setelah `juicefs mount`.
   Belum diuji cukup untuk disebut sebab.

**Alasan memilih native bukan kecepatan**, melainkan mount point bebas, lepas
dari jebakan `smb://localhost`, dan tidak kena batas satu-mount-per-share.

### Redis native (brew) vs Redis lewat OrbStack ✅

Pertanyaannya: apakah metadata yang dilayani lewat port-forward OrbStack
(`127.0.0.1:6380`) menahan client native? Diuji dengan menyalin metadata
(`juicefs dump` → `juicefs load`) ke Redis brew yang jalan langsung di macOS,
lalu mount **read-only** dari sana.

> Ini membuat **salinan metadata kedua di atas bucket R2 yang sama**. Kalau
> keduanya sama-sama menulis, metadata bercabang dan objek jadi yatim. Mount uji
> wajib `--read-only --no-bgjob --backup-meta 0`, dan salinannya dihapus setelah
> selesai.

**Baca berurutan 166 MiB — tidak ada beda:**

| | Median | Rentang |
|---|---|---|
| Metadata via OrbStack | 15,5 MiB/s | 14,6–21,7 |
| Metadata via brew native | 16,0 MiB/s | 12,9–20,8 |

Masuk akal: membaca satu berkas besar hanya butuh segelintir operasi metadata,
sisanya lalu lintas data ke R2.

**Operasi metadata — bedanya nyata.** 4.945 entri, `os.lstat` tiap entri, cache
metadata dimatikan (`--attr-cache 0 --entry-cache 0 --dir-entry-cache 0`) supaya
tiap `stat` benar-benar memukul Redis:

| Metadata engine | stat/s | ms per stat |
|---|---|---|
| Redis 7.4.10 di container | 634 | 1,58 |
| Redis 8.8.0 di container | 633 | 1,58 |
| **Redis 8.8.1 native (brew)** | **871** | **1,15** |

**1,37× lebih cepat**, dengan variasi antar-sampel di bawah 1%.

Yang penting dari baris tengah: menaikkan versi Redis **tidak berpengaruh sama
sekali** (633 vs 634). Seluruh selisihnya datang dari hop container.

### Jebakan: microbenchmark PING menyesatkan

`redis-benchmark -t ping` memberi gambaran yang salah:

| | p50 PING | stat/s sungguhan |
|---|---|---|
| Redis 7 container | 0,119 ms | 634 |
| Redis 8 container | 0,095 ms | 633 |
| Redis 8 brew native | 0,079 ms | 871 |

PING menyimpulkan naik versi 7→8 memangkas latensi 20% — padahal beban kerja
sungguhan tidak bergerak sedikit pun. Selisih PING native vs container juga
cuma 0,016 ms, sementara selisih per `stat` mencapai **0,43 ms** — 27× lebih
besar. Mekanismenya belum dijelaskan; yang jelas ongkos port-forward tidak
terwakili oleh PING.

**Kesimpulan praktis:** pindah ke Redis brew berguna kalau beban kerjamu banyak
`ls`, `find`, `stat`, atau berkas kecil. Untuk memindahkan berkas besar,
percuma. Repo ini tetap memakai Redis container demi kesatuan `docker compose`
— memindahkan metadata ke luar berarti kehilangan `depends_on`, healthcheck, dan
backup-on-stop di `entrypoint.sh`.

### Baca kedua (warm) tidak terukur dengan metode ini

| | Hasil `dd` |
|---|---|
| Native warm | 8,0–10,4 GB/s |
| SMB warm | 12,4–15,2 GB/s |

Angka belasan GB/s itu **RAM, bukan filesystem.** Page cache macOS menyajikan
seluruh berkas 166 MiB tanpa menyentuh disk maupun jaringan. Pembandingnya:
membaca berkas cache JuiceFS langsung dari SSD, di luar FUSE, hanya **921
MiB/s** — jauh di bawah angka "warm" di atas.

Untuk mengukur cache disk yang sebenarnya, perlu `sudo purge` sebelum tiap
sampel. Belum dilakukan. Angka 357 MB/s di [Performa](performa-dan-biaya.md)
kemungkinan mengandung bias yang sama.

---

## Opsional: `-o local` dan jebakan Spotlight

Tanpa `local`, macFUSE menandai volume sebagai *network volume* — muncul di
Finder tapi tidak diindeks Spotlight. Menambahkan `local` ke daftar `-o`
membuatnya diperlakukan sebagai disk lokal (sidebar, ikon desktop, perilaku
lebih "native").

Konsekuensinya: **`mds` akan mengindeks seluruh isi volume.** Untuk file system
di atas object storage, itu berarti membaca ulang semua block dari R2 — operasi
Class B plus egress, dipicu oleh proses latar yang tidak kamu minta.

Kalau tetap mau `local`, daftarkan mount point ke
**System Settings → Spotlight → Search Privacy** *sebelum* mount pertama.

---

## Migrasi penuh: Docker → native ✅

Dijalankan 29 Juli 2026. **Ini yang sekarang berjalan.** Docker tidak lagi
dipakai untuk operasi harian.

```
SEBELUM                              SESUDAH

Finder ──SMB──► Samba (container)    Finder ──► macFUSE
                     │                              │
                JuiceFS (container)            JuiceFS (proses macOS)
                     │        │                     │        │
                    R2   Redis (container)         R2   Redis (brew, launchd)
```

### Urutan yang dipakai

Metadata adalah titik kegagalan tunggal, jadi urutannya: backup → hentikan
semua penulis → migrasi → **verifikasi** → baru potong.

```bash
# 1. Backup pra-migrasi
juicefs dump redis://127.0.0.1:6380/2 dumps/pra-migrasi-$(date +%Y%m%d-%H%M%S).json

# 2. Catat baseline untuk verifikasi
find ~/jfs | wc -l                      # 4946 entri
shasum -a 256 ~/jfs/<beberapa berkas>   # simpan hasilnya

# 3. Hentikan SEMUA penulis — dump yang diambil selagi ada yang menulis
#    menghasilkan metadata yang tidak konsisten
juicefs umount ~/jfs
docker compose stop juicefs

# 4. Siapkan Redis brew (lihat bagian berikutnya), lalu pindahkan
juicefs dump redis://127.0.0.1:6380/2 migrasi.json
juicefs load redis://127.0.0.1:6379/2 migrasi.json
juicefs config redis://127.0.0.1:6379/2 --secret-key "$R2_SECRET_KEY"   # WAJIB

# 5. Verifikasi SEBELUM memutus — mount read-only dari metadata baru
juicefs mount redis://127.0.0.1:6379/2 ~/jfs-verifikasi --read-only --no-bgjob -d
find ~/jfs-verifikasi | wc -l           # harus sama dengan baseline
shasum -a 256 ...                       # checksum harus identik

# 6. Baru potong
docker compose down                     # volume TIDAK dihapus
```

Hasil verifikasi: 4.946 entri sama persis, tiga checksum identik.

> `juicefs dump` **selalu** membuang secret key. Tanpa langkah `config
> --secret-key`, volume ter-mount tapi setiap pembacaan data gagal — dan
> pesannya tidak menyebut soal kredensial. Sama seperti di
> [Backup metadata](backup.md#langkah-2-paling-mudah-terlewat).

### Redis brew

```bash
brew install redis
brew services start redis        # autostart saat login
```

Dua baris di `/opt/homebrew/etc/redis.conf` yang tidak boleh dilewat:

```
appendonly yes
maxmemory-policy noeviction
```

| Setelan | Kalau salah |
|---|---|
| `appendonly no` (default brew) | Redis cuma menyimpan snapshot berkala; perubahan sejak snapshot terakhir hilang saat crash |
| `maxmemory-policy` selain `noeviction` | Redis boleh membuang key saat memori penuh — **metadata ikut terbuang**, dan data di R2 jadi blok anonim |

`bind 127.0.0.1 ::1` sudah jadi default brew, jadi Redis tidak terbuka ke WiFi.
Sama seperti pengikatan loopback di `docker-compose.yml`.

### Yang mengambil alih tugas container

| Tugas | Dulu | Sekarang |
|---|---|---|
| Mount | container + Samba | `mount-native.sh` via LaunchAgent |
| Metadata engine | container `jfs-redis` | Redis brew, `brew services` |
| Backup 1 jam ke R2 | `--backup-meta 1h` di container | flag yang sama di `mount-native.sh` |
| Backup harian ke disk | `backup-meta.sh` lewat `docker compose exec` | `backup-meta.sh` langsung, tanpa Docker |
| Dump saat berhenti | `BACKUP_ON_STOP` di `entrypoint.sh` | **tidak ada penggantinya** |

**Lapis backup ketiga itu hilang.** Sebagai gantinya, agent backup harian
(`com.juicefs.lab.backup`) sekarang **dipasang**, bukan sekadar template —
dulu tidak dipasang karena container sudah melakukan dump tiap kali berhenti.

### LaunchAgent

Dua agent terpasang di `~/Library/LaunchAgents/`:

| Label | Fungsi |
|---|---|
| `com.juicefs.lab.mount` | mount saat login, pasang ulang kalau mati |
| `com.juicefs.lab.backup` | dump metadata ke `dumps/` tiap hari 12:00 |

`mount-native.sh` menjalankan `juicefs mount` di **foreground** — sengaja, tanpa
`--background`. Kalau prosesnya daemonize, launchd melihatnya langsung selesai
lalu menghidupkannya berulang-ulang.

Skrip juga menunggu Redis sampai 60 detik sebelum menyerah, karena `brew
services` dan LaunchAgent sama-sama jalan saat login tanpa urutan yang dijamin.

Diuji: `juicefs umount ~/jfs` → **dipasang ulang otomatis dalam 17 detik**.

```bash
launchctl list | grep juicefs      # lihat status
tail -f dumps/mount.log            # log mount
```

---

## Muncul di Finder tanpa diindeks Spotlight ✅

Dua syarat yang saling bertentangan: `-o local` membuat Finder memperlakukannya
sebagai disk (muncul di sidebar), tapi volume lokal justru yang diindeks
Spotlight — dan mengindeks file system di atas object storage berarti membaca
ulang semua block dari R2.

Yang dipakai:

```bash
-o volname=JuiceFS,local                   # terlihat sebagai disk di Finder
touch ~/jfs/.metadata_never_index          # penanda: jangan indeks volume ini
```

`mdutil -i off ~/jfs` **tidak bisa dipakai** di sini — karena mount point ada di
dalam home, `mdutil` menerjemahkannya ke `/System/Volumes/Data/...` lalu menolak
dengan `unknown indexing state`. Penanda `.metadata_never_index` tidak punya
masalah itu.

**Diuji, bukan diasumsikan:**

| Langkah | Hasil |
|---|---|
| Tulis berkas bertoken unik di `~/jfs`, tunggu 45 detik | `mdfind` → tidak ditemukan |
| Kontrol: token serupa di `~/Documents`, tunggu 40 detik | `mdfind` → **ditemukan** |
| `.Spotlight-V100` di root volume | tidak ada |

Kontrol itu yang membuat hasilnya berarti — tanpa itu, "tidak ditemukan" bisa
saja cuma berarti indexer-nya lambat.

> `tmutil addexclusion ~/jfs` **gagal** dengan `Invalid argument` — Time Machine
> tidak menerima path FUSE. TM memang tidak mencadangkan volume FUSE secara
> default, tapi kalau kamu memakai Time Machine, pastikan sendiri lewat
> System Settings → Time Machine → Options.

---

## Rollback

### Kembali ke jalur Docker

Metadata sekarang ada di Redis brew, dan Redis container **masih menyimpan
salinan lama** di volume `juicefs-lab_redis-data` — tapi salinan itu membeku di
waktu migrasi. Perubahan setelahnya hanya ada di Redis brew.

```bash
# 1. Hentikan jalur native lebih dulu — dua client di atas metadata berbeda
#    yang menulis ke bucket yang sama akan membuat objek yatim
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.mount.plist
juicefs umount ~/jfs

# 2. Pindahkan metadata BALIK, jangan pakai yang lama
docker compose up -d redis
juicefs dump redis://127.0.0.1:6379/2 balik.json
docker compose exec -T redis redis-cli -n 2 flushdb      # buang salinan beku
juicefs load redis://127.0.0.1:6380/2 balik.json
juicefs config redis://127.0.0.1:6380/2 --secret-key "$R2_SECRET_KEY"

# 3. Baru hidupkan client container
docker compose up -d
```

### Melepas macFUSE sepenuhnya

```bash
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.mount.plist
juicefs umount ~/jfs
brew uninstall --cask macfuse
brew services stop redis         # kalau tidak dipakai lagi
```

Lalu kembalikan security policy: Recovery Mode → Startup Security Utility →
**Full Security**.

---

## Yang perlu diukur setelah berhasil

Repo ini punya kebiasaan mencatat angka, bukan kesan. Daftar yang belum terjawab:

- [x] `._*` nihil dengan `--enable-xattr` saja — terverifikasi, 0 berkas `._*` setelah menyalin 187 berkas ber-xattr
- [ ] Apakah Finder masih memunculkan -8062 setelah `noappledouble` dicabut — perlu dicoba ulang dari Finder
- [x] Dua client (container + Mac) mount bersamaan — terverifikasi
- [x] Baca cold vs SMB — 9 sampel per jalur, [hasilnya di atas](#performa-native-vs-smb-)
- [ ] Baca dari cache lokal — **butuh `sudo purge`** sebelum tiap sampel, kalau
      tidak yang terukur cuma page cache RAM
- [x] Apakah Redis lewat OrbStack menahan client native — [ya, tapi hanya untuk metadata](#redis-native-brew-vs-redis-lewat-orbstack-)
- [ ] Kenapa native kadang jatuh ke 8,1 MiB/s (persis 20,4 detik) sementara SMB tidak pernah
- [ ] Kenapa ongkos port-forward per `stat` (0,43 ms) 27× lebih besar dari selisih PING (0,016 ms)
- [ ] Tulis berkas 200 MB, bandingkan dengan angka buffer di `.env`
- [ ] Perilaku trash saat hapus dari Finder (`TRASH_DAYS`)
- [ ] Tulis bersamaan dari container dan Mac ke direktori **sama** (uji di atas hanya berurutan)
- [ ] Pemakaian RAM proses `juicefs` di macOS
- [ ] Apa yang terjadi saat OrbStack dimatikan selagi ter-mount

Kalau native terbukti lebih baik, `ENABLE_SMB=false` di `.env` mematikan Samba —
container tetap dibutuhkan untuk backup metadata terjadwal.

---

## Rujukan

- [macFUSE — Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)
- [macFUSE — FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- [macFUSE — Mount Options](https://github.com/macfuse/macfuse/wiki/Mount-Options)
- [Rilis macFUSE](https://github.com/macfuse/macfuse/releases)
- [Instalasi JuiceFS](https://juicefs.com/docs/community/installation/)
