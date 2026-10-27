# Temuan teknis

Hal-hal yang tidak terdokumentasi dengan baik di tempat lain, atau yang
dokumentasinya sudah tidak sesuai kenyataan. Semuanya diverifikasi langsung
pada **JuiceFS 1.4.0 + Cloudflare R2 + macOS**.

[← kembali ke README](../README.md)

---

## 1. Dokumentasi JuiceFS soal batasan R2 sudah usang

Dokumentasi resmi JuiceFS — termasuk di tag v1.4.0 — masih menyatakan:

> Cloudflare R2 `ListObjects` API is not fully S3 compatible (result list is not
> sorted), so some features of JuiceFS do not work. For example, `juicefs gc`,
> `juicefs fsck`, `juicefs sync`, `juicefs destroy`. And when using
> `juicefs mount`, you need to disable automatic-backup by adding
> `--backup-meta 0`.

**Peringatan itu tidak lagi berlaku.**

| | |
|---|---|
| Issue [#3144](https://github.com/juicedata/juicefs/issues/3144) | ditutup COMPLETED, 26 Sep 2025 |
| PR [#6389](https://github.com/juicedata/juicefs/pull/6389) | *"allow unordered list in fsck/backup/gc/destroy commands"* — merged 26 Sep 2025 |
| Berkas yang diubah | `gc.go`, `fsck.go`, `destroy.go`, `format.go`, `vfs/backup.go` |
| Masuk v1.4.0? | ya — v1.4.0 berjarak 438 commit di depan fix itu |
| Dokumentasi | tidak pernah diperbarui |

### Hasil pengujian

| Yang diuji | Hasil |
|---|---|
| ListObjectsV2 — 476 key, 1 halaman | ✅ terurut benar |
| ListObjectsV2 — 1076 key, **2 halaman** | ✅ terurut, 1076 unik, tanpa duplikat |
| `juicefs fsck` | ✅ 474 block, 345 slice, tanpa error |
| `juicefs gc` | ✅ 0 leaked |
| `juicefs gc --delete` | ✅ jalan, checksum data identik sebelum & sesudah |
| `juicefs sync` | ✅ 20 object, 0 gagal |
| `juicefs destroy` | ✅ 479 object terhapus, bucket jadi 0 B |
| `--backup-meta 1h` | ✅ dump muncul di R2 setelah 8 menit |

Uji paginasi adalah yang paling menentukan. Hipotesis awal — bahwa masalah
urutan baru muncul setelah melewati batas 1000 key — **tidak terbukti**. Batas
halaman dilewati mulus di key ke-1000 menuju 1001, urutan tetap rapi, tanpa
duplikat maupun key hilang.

### Kesimpulan

Perlakukan R2 sebagai object storage biasa. Tidak ada perintah yang perlu
dihindari, dan `--backup-meta 0` tidak diperlukan.

### Peringatan yang tetap berlaku

Cloudflare **tidak pernah menjanjikan** urutan leksikografis di dokumentasinya
— mereka hanya menyatakan ListObjectsV2 "terimplementasi". Yang terbukti di
atas adalah *perilaku saat ini*, bukan *kontrak*. Secara teknis Cloudflare
bebas mengubahnya tanpa melanggar apa pun.

Pengujian juga memakai pola key seragam (`chunks/0/25/25117_0_8`). Laporan
komunitas soal urutan aneh di R2 mungkin terkait karakter khusus atau delimiter
yang tidak muncul di pola JuiceFS.

Verifikasi ulang setelah upgrade JuiceFS atau perubahan besar di sisi R2.

---

## 2. `--enable-xattr` wajib kalau memakai Samba

Samba menyimpan metadata macOS lewat modul `streams_xattr`, yang membutuhkan
dukungan extended attribute dari filesystem. **JuiceFS mematikan xattr secara
default** (`--enable-xattr` default `false`).

Tanpa flag itu:

```
setxattr GAGAL: [Errno 95] Operation not supported
```

Samba lalu jatuh ke mode membuat berkas AppleDouble **sungguhan** — bukan
sekadar tampilan.

| | Tanpa `--enable-xattr` | Dengan |
|---|---|---|
| Salin 1 berkas dari Finder | `._namafile` 4 KB ikut tersimpan | tidak ada |
| 10.000 berkas | 10.000 object sampah | 0 |
| Biaya di R2 | 10.000 operasi Class A terbuang | 0 |

Gejalanya halus: Samba jalan, mount berhasil, berkas tersalin dengan checksum
benar. Yang rusak hanya kebersihan storage — dan baru terasa saat tagihan
operasi membengkak.

Cara memeriksa:

```bash
docker compose exec juicefs python3 -c "
import os; os.setxattr('/mnt/jfs/.config','user.k',b'v'); print('xattr aktif')"
```

---

## 3. Finder macOS memblokir `smb://localhost`

macOS menganggapnya koneksi ke dirinya sendiri dan memblokirnya di lapisan
NetFS. Errornya menyesatkan:

> There was a problem connecting to the server "localhost".
> The server may not exist or it is unavailable at this time.

Padahal server berjalan normal. Buktinya: **log Samba tidak mencatat percobaan
koneksi sama sekali** — permintaannya tidak pernah keluar dari macOS.

`mount_smbfs` dari terminal tetap bisa memakai `localhost` karena melewati
lapisan NetFS itu.

> **Gejala khas: CLI berhasil, Finder gagal.**

Solusinya memakai nama host OrbStack (`jfs-client.orb.local`) atau IP container
langsung:

```bash
docker inspect jfs-client --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

Nama host lebih disarankan karena stabil walau IP container berubah.

### Terkait: hanya satu mount per share

macOS menolak me-mount share SMB yang sama dua kali. Kalau volume sudah
ter-mount lewat terminal, Finder akan gagal dengan error yang sama
membingungkannya.

```bash
mount | grep smbfs      # cek
umount /Volumes/jfs     # lepas yang tidak dipakai
```

---

## 4. `/mnt/jfs` akan terlihat kosong dari macOS

`/mnt/jfs` adalah FUSE mount **di dalam container**. Di macOS, path `/mnt`
bahkan tidak ada sama sekali.

Lewat file browser OrbStack
(`~/OrbStack/docker/containers/jfs-client/mnt/jfs`) juga terlihat kosong.

**Itu normal, bukan bug.** OrbStack mengekspos *layer filesystem* container,
sedangkan FUSE mount adalah mount kernel di mount namespace container — bukan
bagian dari filesystem. Sebagai pembanding, `/var/jfsCache` lewat OrbStack
tetap terlihat isinya, karena itu memang direktori biasa.

Hasilnya identik dengan menjalankan `umount /mnt/jfs`: direktori kosong.
Berkasnya hanya "ada" saat dilihat melalui lapisan FUSE.

### Bind mount juga tidak menolong

Diuji langsung: mount JuiceFS ke dalam folder yang di-bind dari macOS.

```
DI CONTAINER : JuiceFS:myjfs-r2 on /shared/jfs-test type fuse.juicefs  ✅
DI MAC       : 0 berkas                                                 ❌
```

Alasannya arsitektural. Bind mount mengalir **satu arah**: macOS → VM Linux →
container. Menumpuk FUSE mount di atasnya *di dalam* container membuat tumpukan
itu hidup di mount namespace container, dan tidak pernah mengalir balik.

Satu-satunya jalan mengeluarkan isi FUSE mount ke macOS adalah membagikannya
lewat protokol jaringan — itulah fungsi Samba di repo ini.

---

## 5. SMB lebih aman daripada WebDAV untuk Finder

JuiceFS menyediakan server WebDAV bawaan, dan Finder bisa me-mount-nya. Tapi
dalam pengujian, **Finder lewat WebDAV pernah menghapus seluruh isi volume**
saat operasi penyalinan berkas besar — 671 MB, termasuk berkas yang tidak
sedang disentuh.

Semuanya bisa dipulihkan dari `.trash`, tapi itu bukan risiko yang layak
diambil untuk pemakaian sehari-hari.

Apple memakai SMB sebagai protokol utama macOS, jadi Finder memperlakukannya
sebagai volume kelas satu dan tidak melakukan trik penulisan-lalu-timpa seperti
pada WebDAV.

Di repo ini WebDAV default-nya **mati**, tersedia sebagai cadangan lewat
`ENABLE_WEBDAV=true`.

### Kalau tetap memakai WebDAV

- Aman untuk membaca dan mengunduh
- Hindari menulis berkas besar dari Finder
- Pastikan `TRASH_DAYS` tidak 0

---

## 6. `valid users` di `smb.conf` mendua dengan `SMB_USER`

Versi awal `smb.conf` menuliskan `valid users = jfs` di dalam share `[jfs]`,
sementara akun Samba dibuat entrypoint dari `SMB_USER` di `.env`. Selama
`SMB_USER` masih bernilai default `jfs`, keduanya kebetulan cocok dan semuanya
tampak baik-baik saja.

Begitu `SMB_USER` diganti, share menolak semua koneksi.

### Kenapa sulit didiagnosis

Kegagalannya terjadi **setelah** autentikasi berhasil, bukan saat login. Samba
menerima password, membuat sesi, lalu menolak saat share dibuka:

```
create_connection_session_info: user 'rizkirmdhn' (from session setup)
  not permitted to access this share (jfs)
make_connection_snum: ... NT_STATUS_ACCESS_DENIED
```

Masalahnya, macOS tidak meneruskan pesan itu. Yang sampai ke pemakai:

| Cara mount | Pesan yang muncul |
|---|---|
| `mount_smbfs` | `No such file or directory` |
| Finder (`Cmd+K`) | `An error of type -5018 has occurred` |

Dua-duanya tidak menyebut izin sama sekali, dan yang pertama malah mengarahkan
dugaan ke path yang salah atau share yang tidak ada. `smbutil view` pun tetap
menampilkan share `jfs` dengan normal, karena melihat daftar share tidak
melewati pemeriksaan `valid users`. Satu-satunya petunjuk jujur ada di
`/var/log/samba/smbd.log` di dalam container.

### Perbaikannya: hapus, bukan sinkronkan

Godaan pertama adalah membuat entrypoint menyalin `SMB_USER` ke baris
`valid users` saat start. Itu berhasil, tapi mengobati gejala — ia
mengotomatiskan penyelarasan dua tempat yang seharusnya tidak pernah ada
duanya, dan membuat `smb.conf` di dalam container berbeda dari yang ada di
repo.

Di setup ini `valid users` sebenarnya tautologis. Daftar akses share sudah
dijamin oleh rantai berikut:

- `security = user` — tidak ada akses tanpa akun
- `map to guest = never` — tidak ada jatuh-ke-guest
- `guest ok = no` pada share
- passdb hanya pernah diisi `smbpasswd -a "$SMB_USER"` oleh entrypoint
- passdb ada di `/var/lib/samba/private/`, di layer container dan **bukan**
  volume — jadi ikut terhapus tiap container di-recreate

Artinya `valid users = $SMB_USER` cuma menyatakan ulang fakta yang sudah
dipegang passdb. Barisnya dihapus, dan diganti komentar yang menjelaskan kenapa
ia sengaja tidak ada — baris yang hilang itu tak terlihat, dan tanpa penjelasan
gampang ditambahkan kembali dengan niat baik.

`SMB_USER` kini juga divalidasi formatnya di entrypoint sebelum dipakai, karena
nilai itu mengalir ke `useradd` dan `smbpasswd`.

### Catatan untuk Samba secara umum

`smb.conf` **tidak** mengenal variabel environment — hanya makro Samba sendiri
(`%U`, `%S`, `%m`, dan seterusnya). Jadi kalau suatu nilai memang harus ikut
`.env`, tidak ada jalan selain membangkitkan config-nya.

Dan `valid users = %U` bukan jalan pintas yang sah: `%U` adalah username sesi
yang sedang login, jadi ia selalu cocok. Kelihatan seperti pembatasan, padahal
mematikannya.

---

## 7. `-o noappledouble` membuat salinan Finder gagal (-8062)

Berlaku di jalur **native macFUSE**.

Gejalanya: menyalin folder dari Finder ke volume JuiceFS berhenti dengan

> The operation can't be completed because an unexpected error occurred
> (error code -8062).

Penyebabnya opsi mount `noappledouble`. Namanya menyiratkan ia cuma mengurus
berkas AppleDouble (`._*`), tapi [dokumentasi macFUSE](https://github.com/macfuse/macfuse/wiki/Mount-Options)
menyebut ia menolak akses ke `._*` **dan `.DS_Store`** — "new files that match
the criteria will be disallowed from being created".

Finder membuat `.DS_Store` di hampir setiap folder yang ia sentuh. Penolakan itu
muncul sebagai `ENOENT`, dan Finder memperlakukannya sebagai kegagalan fatal.

Cara memastikan dalam sedetik:

```bash
touch ~/jfs/.DS_Store
# noappledouble aktif → touch: ...: No such file or directory
```

Yang menyesatkan: berkas dotfile biasa (`.biasa`) tetap bisa dibuat, jadi
kelihatannya bukan soal nama berawalan titik.

**Opsi itu tidak diperlukan.** `--enable-xattr` sendiri sudah mencegah berkas
`._*`, karena macOS bisa menyimpan xattr secara native. Terukur: menyalin 187
berkas ber-xattr (`com.apple.FinderInfo`, `com.apple.metadata:*`) tanpa
`noappledouble` menghasilkan **0 berkas `._*`**.

### Batasan terpisah: FinderInfo dan flag `hidden` tidak bisa ditulis

Ditemukan saat melacak yang di atas, dan **belum ada solusinya**. Berkas yang
membawa FinderInfo tidak nol (bit invisible) atau flag BSD `hidden` gagal dengan
`Input/output error` saat disalin dengan `ditto`:

| Berkas uji | Hasil |
|---|---|
| Hanya flag `hidden` | EIO |
| Hanya FinderInfo (bit invisible) | EIO |
| Polos | lolos |
| Sama, tapi ke disk Mac biasa | lolos |

Bukan soal nama berkas (berkas sama dengan nama lain tetap gagal), bukan soal
opsi `local` (gagal dengan maupun tanpa). `chflags hidden` sendiri mengembalikan
sukses tapi tidak menyimpan apa pun — dibaca balik, flagnya kosong.

Yang perlu diketahui: **isi berkasnya tetap tersalin utuh** — `.DS_Store` 22.532
byte sampai lengkap. Yang gagal hanya penulisan atributnya. Menyetel
`com.apple.FinderInfo` lewat `xattr -w` juga berhasil; yang gagal adalah jalur
yang dipakai `ditto`/`copyfile`.

---

## Ringkasan

| Temuan | Dampak kalau diabaikan |
|---|---|
| `-o noappledouble` di mount native | salinan folder dari Finder gagal dengan error yang tidak menyebut sebabnya |
| Dokumentasi R2 usang | menghindari perintah yang sebenarnya berfungsi |
| `--enable-xattr` mati | storage kotor, operasi Class A terbuang |
| `smb://localhost` diblokir | menghabiskan waktu men-debug server yang sehat |
| `/mnt/jfs` kosong dari Mac | mengira data hilang padahal aman |
| WebDAV untuk menulis | kehilangan berkas massal |
| `valid users` ditulis manual | ganti `SMB_USER` bikin share tertutup, dengan pesan error yang menyesatkan |
