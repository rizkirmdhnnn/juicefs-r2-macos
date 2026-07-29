# Performa, biaya, dan batasan

[← kembali ke README](../README.md)

Semua angka diukur langsung pada MacBook Apple Silicon, OrbStack, R2 default
jurisdiction, koneksi rumahan Indonesia.

---

## Performa

| | Hasil |
|---|---|
| Tulis 20 MiB ke R2 | 2,79 s (~7,5 MB/s) |
| Baca 20 MiB dingin dari R2 | 2,34 s (~8,6 MB/s) |
| **Baca 20 MiB dari cache lokal** | **0,056 s (~357 MB/s)** |
| Stat berkas (metadata) | 29.557 ops/s |
| Update metadata | 0,88 ms/op |

### Cache menentukan segalanya

Selisih baca dingin vs hangat: **42×**. Performa JuiceFS nyaris seluruhnya
ditentukan cache hit rate, bukan kecepatan object storage. `CACHE_SIZE` adalah
pengaturan paling berharga di `.env`.

### Metadata tidak terpengaruh jarak

`Stat berkas` 29.557 ops/s dan `Update metadata` 0,88 ms — sama sekali tidak
terpengaruh oleh data yang ada di seberang lautan, karena dilayani Redis lokal.

Inilah keuntungan arsitektur pemisahan data/metadata: `ls`, `stat`, `find`,
dan `du` tetap ngebut walaupun datanya di Cloudflare. s3fs tidak bisa
memberikan ini.

### Hasil `juicefs bench` penuh

4 GiB (1 GiB × 4 thread), 12 menit:

| Item | Nilai |
|---|---|
| Write big file | 11,46 MiB/s |
| Read big file | 12,29 MiB/s |
| Write small file | 10,9 berkas/s |
| Read small file | 4.763 berkas/s |
| Stat file | 29.557 berkas/s |
| Put object | 4.019 ms/op |
| Get object | 4.376 ms/op |

`Write small file` 10,9 berkas/s adalah angka yang paling perlu diperhatikan —
tiap berkas kecil berarti satu PUT bolak-balik ke R2. Untuk dataset dengan
ratusan ribu berkas kecil, pertimbangkan `--writeback` (dengan risikonya) atau
mengarsipkan dulu.

### Catatan pengukuran

Angka baca lewat SMB dari Finder **tidak bisa dipercaya** untuk benchmark —
macOS SMB client punya cache sendiri di atas cache JuiceFS. Pengukuran di atas
dilakukan dari dalam container setelah mengosongkan cache dan me-restart
container.

---

## Tuning buffer — hasil pengukuran

Menyalin berkas 200 MB dari Finder lewat SMB, diukur dengan `juicefs stats`:

| | buffer 128 MiB | buffer 300 MiB (default) | buffer 600 MiB |
|---|---|---|---|
| Waktu salin | 22,1 s | seimbang | **18,5 s** |
| Puncak buffer | 132M — **penuh** | — | 204M — lapang |
| `fuse write` puncak | 30M lalu **0** | — | **59M** |
| RAM jfs-client | 86 MB | ~143 MB | **368 MB** |

Kolom `fuse write` menjelaskan gejalanya. Saat buffer penuh, penulisan dari
Finder **berhenti total** menunggu unggahan menguras isinya — inilah "kadang
cepat kadang lambat" yang terasa saat menyalin berkas besar.

Unggahan ke R2 sendiri memang tidak stabil (`object put` berayun 5–24 MB/s).
Buffer besar **menyembunyikan** ketidakstabilan itu; buffer kecil
**meneruskannya** langsung ke Finder.

### Konsekuensi buffer besar

Saat `cp` selesai, sebagian data masih di RAM dan **belum sampai R2**. Shutdown
bersih menanganinya — `umount` menunggu flush tuntas — tapi kernel panic atau
listrik padam tidak. Buffer kecil berarti lebih banyak data sudah aman di R2
saat penyalinan dilaporkan selesai.

### Kesimpulan

300 MiB (default JuiceFS) adalah titik seimbang. 600 MiB memang lebih cepat
16%, tapi 368 MB RAM menghapus seluruh manfaat penghematan.

`--max-downloads 32` aman diturunkan dari default 200 — memengaruhi baca, dan
pengukuran tidak menunjukkan penurunan pada koneksi rumahan.

## Biaya

Tarif R2 (per Juli 2026):

| | Standard | Infrequent Access |
|---|---|---|
| Storage | $0,015/GB-bulan | $0,010/GB-bulan |
| Class A (tulis/list) | $4,50/juta | $9,00/juta |
| Class B (baca) | $0,36/juta | $0,90/juta |
| Egress | **gratis** | **gratis** |

Gratis tiap bulan: 10 GB storage, 1 juta Class A, 10 juta Class B.

### Perbandingan pada 500 GB

| Skenario | R2 | S3 (compute di AWS) | S3 (compute di luar AWS) |
|---|---|---|---|
| Arsip, jarang dibaca | $7,35 | $11,53 | $11,53 |
| Kerja aktif | $7,35 | $11,57 | $11,57 |
| Training AI, baca 2 TB/bln | **$7,35** | $11,77 | **$182,77** |

Total tahun pertama untuk skenario terakhir: **$88 vs $2.194**.

### Tiga hal penting

**R2 tetap $7,35 di semua skenario.** Free tier 10 juta Class B per bulan
menelan hampir semua operasi baca di skala ratusan GB. Praktisnya kamu hanya
membayar storage.

**Egress adalah pemisah sesungguhnya.** Selisih storage antara R2 dan S3 kecil.
Tapi begitu compute berada di luar AWS dan pembacaannya intensif, selisihnya
jadi 25 kali lipat. Setup ini — JuiceFS di laptop, bukan di EC2 — persis
kondisi itu.

**Berkas kecil adalah satu-satunya tempat R2 menagih operasi.** Mengunggah 5,2
juta berkas 100 KB menghabiskan ~$19 sekali bayar untuk Class A.

### Jumlah object menurut profil berkas

JuiceFS memecah berkas jadi block 4 MiB. Untuk 500 GB:

| Profil | Jumlah berkas | Jumlah object |
|---|---|---|
| Berkas besar (avg 500 MB) | 1.024 | 128.000 |
| Campuran (avg 2 MB) | 256.000 | 256.000 |
| Dataset AI (avg 100 KB) | 5.242.880 | **5.242.880** |

`--block-size` lebih besar memangkas jumlah operasi tapi menambah read
amplification saat random read. Hanya bisa diatur saat `format`, tidak bisa
diubah belakangan.

### Biaya tersembunyi terbesar

**Redis tidak gratis.** Metadata JuiceFS hidup di RAM. Untuk 500 GB dengan 5
juta berkas, Redis butuh sekitar 1,5 GB RAM. Kalau tidak di laptop sendiri, itu
VPS ~$10–20/bulan — **lebih mahal daripada storage R2-nya**.

---

## Batasan dan penskalaan

### Redis menyimpan metadata di RAM

Diukur langsung: **199 byte per berkas**.

| Jumlah berkas | RAM Redis |
|---|---|
| 100.000 | ~20 MB |
| 1 juta | ~200 MB |
| 10 juta | ~2 GB |
| 50 juta | ~10 GB |

Pantau dengan:

```bash
docker compose exec redis redis-cli info memory | grep used_memory_human
```

### Kapan pindah ke PostgreSQL

Ganti lewat `META_URL` di `.env`. Perbandingan yang diukur langsung:

| | Redis | PostgreSQL |
|---|---|---|
| Per berkas | 199 byte **di RAM** | 280 byte **di disk** |
| RAM proses | tumbuh linear | tetap ~41 MB |
| create | 5.060 ops/s | 1.972 ops/s (2,6×) |
| rename | 5.979 ops/s | 1.660 ops/s (3,6×) |
| unlink | 8.221 ops/s | 2.130 ops/s (3,9×) |

> Angka PostgreSQL di atas diukur dengan `synchronous_commit=off`, agar setara
> dengan `appendfsync everysec` milik Redis. Dengan setelan bawaan
> (`synchronous_commit=on`, fsync tiap transaksi), PostgreSQL 9–19× lebih
> lambat — tapi itu perbandingan durabilitas yang tidak setara, bukan
> perbandingan kecepatan.

**Pindah kalau:** berkas melewati ~1 juta, atau Redis melewati ~500 MB RAM,
atau kamu butuh backup yang benar-benar konsisten dengan PITR.

**Tetap di Redis kalau:** volumenya masih kecil dan kamu menghargai latensi
metadata terendah.

Migrasinya tidak menyentuh data di R2 sama sekali:

```bash
juicefs dump   redis://...    dump.json
juicefs load   postgres://... dump.json
juicefs config postgres://... --secret-key "$R2_SECRET_KEY"
```

### Random write bukan kekuatan JuiceFS

Overwrite tidak pernah menimpa object — ia membuat slice baru
(copy-on-write) yang di-overlay saat dibaca. Random write intensif menghasilkan
banyak slice kecil, dan fragmentasi memperlambat pembacaan sampai compaction
berjalan.

Cocok untuk **write-once-read-many**: dataset, arsip, media, backup.
Kurang cocok untuk database transaksional atau workload dengan random write
kecil yang intens.

### Redis di sini satu container

Tanpa replika, tanpa sentinel. Untuk pemakaian serius, pindahkan ke instance
dengan persistence dan replikasi yang benar.
