# Cara memulihkan metadata JuiceFS

Baca ini kalau Redis hilang/rusak dan file system tidak bisa di-mount.
Data di R2 **tidak perlu disentuh** — yang hilang cuma petanya.

## Ada dua sumber backup

1. **Otomatis di R2** (tiap 1 jam) — prefix `myjfs-r2/meta/` di bucket `juicefs`
2. **Lokal di folder ini** (tiap hari 12:00) — `meta-YYYY-MM-DD.json.gz`

Pakai yang paling baru. Kalau R2 masih sehat, sumber 1 lebih mutakhir.

## Prosedur

```bash
cd ~/juicefs-lab

# 1. Siapkan file dump (kalau dari folder ini, buka gzip-nya dulu)
gunzip -k dumps/meta-2026-07-29.json.gz

# 2. Pastikan Redis jalan tapi DB tujuan KOSONG
docker compose up -d redis
docker compose exec redis redis-cli -n 2 dbsize     # harus 0
# kalau tidak 0 dan kamu yakin isinya rusak:
# docker compose exec redis redis-cli -n 2 flushdb

# 3. Restore metadata
docker compose run --rm --entrypoint juicefs juicefs \
  load redis://redis:6379/2 /dumps/meta-2026-07-29.json

# 4. WAJIB — pasang ulang secret key R2
#    juicefs dump SELALU membuang secret key demi keamanan.
#    Tanpa langkah ini restore terlihat "gagal" padahal cuma kurang kredensial.
source .env
docker compose run --rm --entrypoint juicefs juicefs \
  config redis://redis:6379/2 --secret-key "$R2_SECRET_KEY"

# 5. Jalankan seperti biasa
docker compose up -d
```

## Verifikasi

```bash
docker compose exec juicefs ls -lh /mnt/jfs
docker compose exec juicefs md5sum /mnt/jfs/<file-yang-kamu-kenal>
```

Kalau checksum cocok dengan yang kamu ingat, pemulihan berhasil.

## Kalau backup lokal juga hilang

Ambil dari R2 langsung:

```bash
source .env
docker run --rm --entrypoint sh \
  -e AID="$R2_ACCOUNT_ID" -e AK="$R2_ACCESS_KEY" -e SK="$R2_SECRET_KEY" -e BK="$R2_BUCKET" \
  -v "$PWD/dumps:/out" minio/mc:latest -c '
    mc alias set r2 https://$AID.r2.cloudflarestorage.com $AK $SK >/dev/null
    mc ls r2/$BK/myjfs-r2/meta/
    mc cp r2/$BK/myjfs-r2/meta/<nama-file-terbaru> /out/'
```

Lalu ikuti prosedur di atas.

## Yang TIDAK akan menyelamatkanmu

- Backup ini hanya berisi **metadata**. Kalau object di R2 terhapus, dump ini
  tidak bisa mengembalikannya.
- `juicefs load` menolak database yang tidak kosong. Jangan load ke DB yang
  masih berisi volume aktif.
- File yang dibuat **setelah** dump terakhir tidak ada di sini. Datanya masih
  di R2 tapi jadi object yatim — bersihkan dengan `juicefs gc --delete`.

## Uji berkala

Backup yang belum pernah diuji hanyalah asumsi. Tiap beberapa bulan, restore ke
database kosong (misal DB 5) lalu baca satu file — tanpa menyentuh volume aktif:

```bash
docker compose exec juicefs juicefs load redis://redis:6379/5 /dumps/meta-xxx.json
docker compose exec juicefs juicefs config redis://redis:6379/5 --secret-key "$R2_SECRET_KEY"
docker compose exec juicefs sh -c 'mkdir -p /mnt/cek && juicefs mount redis://redis:6379/5 /mnt/cek -d && sleep 3 && ls /mnt/cek'
# selesai:
docker compose exec juicefs sh -c 'umount /mnt/cek'
docker compose exec redis redis-cli -n 5 flushdb
```
