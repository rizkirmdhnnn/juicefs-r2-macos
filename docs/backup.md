# Backup metadata

[← kembali ke README](../README.md)

Metadata adalah **titik kegagalan tunggal**. Kalau Redis hilang, data di R2
masih utuh tapi berubah jadi blok anonim yang tidak bisa dirangkai kembali —
tidak ada cara merekonstruksi nama berkas, struktur direktori, maupun peta
block dari object storage saja.

Repo ini memasang tiga lapis.

> **Sejak pindah ke jalur native (29 Juli 2026), susunannya berubah:**
>
> | Lapis | Status di jalur native |
> |---|---|
> | 1 — tiap jam ke R2 | tetap jalan, sekarang dari client native (`mount-native.sh`) |
> | 2 — saat container berhenti | **hilang** — `entrypoint.sh` tidak lagi dipakai |
> | 3 — harian ke disk | tetap jalan, dan agent launchd-nya kini **dipasang** untuk menutup lubang lapis 2 |
>
> `backup-meta.sh` sudah tidak memakai `docker compose exec`; ia memanggil
> `juicefs dump` langsung ke `META_URL_NATIVE`. Rinciannya di
> [Mount native lewat macFUSE](mount-native-macfuse.md#yang-mengambil-alih-tugas-container).

---

## Lapis 1 — ke R2, tiap jam

Ditangani JuiceFS sendiri lewat `--backup-meta 1h`. Tersimpan ter-gzip di
prefix `<volume>/meta/` dengan rotasi berjenjang otomatis. Tidak perlu
diapa-apakan.

```bash
# lihat backup yang ada
docker run --rm --entrypoint sh \
  -e AID="$R2_ACCOUNT_ID" -e AK="$R2_ACCESS_KEY" \
  -e SK="$R2_SECRET_KEY" -e BK="$R2_BUCKET" \
  minio/mc:latest -c '
    mc alias set r2 https://$AID.r2.cloudflarestorage.com $AK $SK >/dev/null
    mc ls -r r2/$BK/myjfs-r2/meta/'
```

Atur intervalnya lewat `BACKUP_META` di `.env` (`0` untuk mematikan).

> Dokumentasi JuiceFS menyuruh mematikan fitur ini di R2. Itu sudah usang —
> lihat [Temuan teknis](temuan-teknis.md#1-dokumentasi-juicefs-soal-batasan-r2-sudah-usang).

---

## Lapis 2 — ke disk lokal, saat container berhenti

Setiap `docker compose down` / `stop`, entrypoint mem-`juicefs dump` ke
`dumps/shutdown-YYYYMMDD-HHMMSS.json.gz`.

**Kenapa perlu:** `--backup-meta` hanya berjalan tiap jam. Kalau container
dimatikan 59 menit setelah backup terakhir, perubahan metadata di jendela itu
hanya ada di Redis. Selama volume `redis-data` utuh tidak masalah — tapi kalau
rusak atau kena `down -v`, perubahan itu hilang dan berkas yang dibuat di
jendela tersebut jadi object yatim di R2.

Rincian implementasi:

- Dijalankan **setelah** `umount`, supaya menangkap kondisi final termasuk data
  yang baru saja di-flush ke R2
- Diberi `timeout 60` agar tidak menahan shutdown melebihi `stop_grace_period`
- Gagal dengan peringatan kalau Redis sudah berhenti duluan — tidak menggantung
- Rotasi `KEEP_SHUTDOWN_DUMPS` (default 5)

Terukur: `compose stop` 0,31 detik, `compose down` penuh 0,89 detik.

Matikan lewat `BACKUP_ON_STOP=false` di `.env`.

---

## Lapis 3 — manual atau terjadwal

```bash
./backup-meta.sh          # backup sekarang
tail ~/.local/share/juicefs-lab/dumps/backup.log   # riwayat
```

Saat dijalankan lewat LaunchAgent, skrip dan `.env`-nya disalin ke
`~/.local/share/juicefs-lab/` (lihat [`launchd/README.md`](../launchd/README.md)),
jadi `dumps/` di repo tidak lagi dipakai untuk log maupun backup harian.

**Kenapa perlu:** lapis 1 tersimpan di **bucket yang sama** dengan datanya.
Kalau akun R2 bermasalah, kredensial bocor, atau bucket terhapus, backup ikut
hilang bersamaan.

Yang dilakukan skrip:

| | |
|---|---|
| Retensi | 7 harian + 4 mingguan (~5 KB per berkas) |
| Verifikasi | dump harus mengandung `FSTree` + `Setting` sebelum menggantikan yang lama |
| Kalau container mati | **gagal keras**, exit code 1, backup lama tidak tertimpa |
| Log | `dumps/backup.log` |

Skrip menulis ke berkas sementara dulu, baru diganti kalau semua pemeriksaan
lolos — tidak ada momen di mana kamu punya backup setengah jadi.

### Menjadwalkan

Template launchd tersedia di [`launchd/`](../launchd/README.md). **Tidak
dipasang secara default.**

```bash
cp launchd/com.juicefs.lab.backup.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
```

---

## Memulihkan

Prosedur lengkap ada di **[`dumps/CARA-RESTORE.md`](../dumps/CARA-RESTORE.md)**
— sengaja ditaruh di folder backup supaya mudah ditemukan saat panik, termasuk
kalau kamu hanya menyalin folder `dumps/` ke tempat lain.

Ringkasnya:

```bash
# 1. Restore ke database KOSONG
juicefs load redis://redis:6379/2 dump.json

# 2. Pasang ulang secret key — WAJIB
juicefs config redis://redis:6379/2 --secret-key "$R2_SECRET_KEY"

# 3. Mount seperti biasa
docker compose up -d
```

### Langkah 2 paling mudah terlewat

`juicefs dump` **selalu** membuang secret key demi keamanan:

```
WARNING: Secret key is removed for the sake of safety
WARNING: secret key was removed; please correct it with `config` command
```

Tanpa langkah itu, pemulihan akan tampak gagal padahal hanya kurang
kredensial. Ada flag `--keep-secret-key`, tapi itu berarti kredensial R2
tertulis polos di berkas JSON — lebih baik simpan `.env` secara terpisah.

---

## Format dump

| Format | Ukuran relatif | Catatan |
|---|---|---|
| JSON (default) | 1× | bisa dibaca manusia, bisa di-`grep` |
| `--binary` | ~0,5× | restore lebih cepat untuk volume besar |
| `--skip-trash` | lebih kecil | membuang isi trash |

Ukuran dump mengikuti **jumlah berkas**, bukan besar data. Volume 700 MB berisi
26 berkas menghasilkan dump 5 KB. Satu juta berkas kecil akan jauh lebih besar
daripada satu berkas 500 GB.

---

## Uji berkala

Backup yang belum pernah diuji hanyalah asumsi. Tiap beberapa bulan, restore ke
database kosong lalu baca satu berkas — tanpa menyentuh volume aktif:

```bash
docker compose exec juicefs juicefs load redis://redis:6379/5 /dumps/meta-xxx.json
docker compose exec juicefs juicefs config redis://redis:6379/5 --secret-key "$R2_SECRET_KEY"
docker compose exec juicefs sh -c 'mkdir -p /mnt/cek && juicefs mount redis://redis:6379/5 /mnt/cek -d && sleep 3 && ls /mnt/cek'

# selesai
docker compose exec juicefs sh -c 'umount /mnt/cek'
docker compose exec redis redis-cli -n 5 flushdb
```

Prosedur ini sudah diverifikasi berhasil: metadata pulih, secret key dipasang
ulang, volume ter-mount, dan checksum berkas identik dengan aslinya.

---

## Yang TIDAK diselamatkan backup ini

- **Object yang terhapus di R2.** Dump hanya berisi metadata. Kalau block-nya
  hilang, peta tidak menolong.
- **Berkas yang dibuat setelah dump terakhir.** Datanya masih di R2 tapi jadi
  object yatim — bersihkan dengan `juicefs gc --delete`.
- **`juicefs load` menolak database yang tidak kosong.** Jangan load ke DB yang
  masih berisi volume aktif.
