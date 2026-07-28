# Keamanan

[← kembali ke README](../README.md)

## Port sengaja tidak di-publish

Compose ini **tidak mem-publish port SMB (445) maupun WebDAV (9007)**. Keduanya
tetap terjangkau dari macOS lewat routing OrbStack di `jfs-client.orb.local`,
tanpa membuka apa pun ke jaringan lokal.

Redis diikat ke `127.0.0.1:6380` saja.

### Kenapa ini penting

Docker mengikat port ke **semua interface** kalau ditulis `"445:445"` —
termasuk Wi-Fi. Siapa pun di jaringan yang sama bisa menjangkaunya.

Yang paling berbahaya bukan SMB, melainkan **Redis**: tanpa password sama
sekali. Satu perintah dari mesin lain di jaringan yang sama sudah cukup:

```bash
redis-cli -h <ip-mac> -p 6380 -n 2 flushdb
```

Metadata hilang, dan seluruh data di R2 berubah jadi blok anonim.

### Aturan penulisan port

```yaml
ports:
  - "127.0.0.1:9007:9007"   # benar — hanya loopback
  - "9007:9007"             # SALAH — terbuka ke seluruh LAN
```

### Memeriksa paparan

```bash
LANIP=$(ipconfig getifaddr en0)
for p in 445 9007 6380; do
  nc -z -G 2 "$LANIP" $p && echo "$p TERBUKA" || echo "$p tertutup"
done
```

Semua harus `tertutup`. Kalau ada yang terbuka, periksa bagian `ports:` di
`docker-compose.yml`.

---

## Kredensial

`.env` berisi Access Key dan Secret Key R2 serta password SMB. Berkas ini
**sudah masuk `.gitignore`** — jangan pernah di-commit.

`.env.example` disediakan sebagai template dengan kredensial R2 kosong.

### Token R2 sebaiknya di-scope

Saat membuat API token di dashboard Cloudflare, pilih permission **Object Read
and Write** lalu **scope-kan ke bucket yang dipakai saja**. Token yang berlaku
untuk seluruh akun memberi akses jauh lebih luas daripada yang dibutuhkan.

### Secret key tidak ikut di backup

`juicefs dump` selalu membuang secret key. Itu perilaku yang benar — tapi
artinya kamu harus menyimpan `.env` di tempat aman secara terpisah, karena
backup metadata saja tidak cukup untuk memulihkan volume.

---

## Pengerasan yang belum dilakukan

Repo ini dirancang untuk pemakaian pribadi di satu mesin. Kalau dipakai lebih
serius, pertimbangkan:

| Hal | Kondisi sekarang | Saran |
|---|---|---|
| Password SMB | tidak ada default | wajib diisi di `.env` |
| Redis | tanpa `requirepass` | aman selama hanya loopback; tambahkan kalau diekspos |
| Redis | satu container, tanpa replika | pindah ke instance dengan persistence + replikasi |
| Samba | berjalan sebagai root di container privileged | terima risikonya, atau ganti ke jalur akses lain |
| Transport | SMB3 dengan signing, tanpa enkripsi paksa | tambahkan `smb encrypt = required` di `smb.conf` |

---

## Kenapa container berjalan `privileged`

FUSE di dalam container membutuhkan `/dev/fuse` dan kapabilitas `SYS_ADMIN`.
Compose memberikan `privileged: true` beserta `cap_add: [SYS_ADMIN]` dan
`security_opt: apparmor:unconfined`.

Ini melonggarkan isolasi container secara signifikan. Untuk lab pribadi di
mesin sendiri, itu wajar. Untuk lingkungan bersama, pertimbangkan
[JuiceFS CSI Driver](https://juicefs.com/docs/csi/introduction) yang menangani
hal ini dengan lebih rapi.

---

## Proteksi `.trash`

`smb.conf` memakai `veto files = /.trash/` sehingga Finder **tidak bisa
melihat, membuka, apalagi menghapus** isi trash.

Ini bukan sekadar kerapian. Trash adalah jaring pengaman terakhir — kalau bisa
dijangkau Finder, satu operasi ceroboh bisa menghapusnya bersamaan dengan
datanya. Kejadian nyata yang melatarbelakanginya ada di
[Temuan teknis](temuan-teknis.md#5-smb-lebih-aman-daripada-webdav-untuk-finder).

Memulihkan berkas dari trash harus lewat container:

```bash
docker compose exec juicefs find /mnt/jfs/.trash -type f
docker compose exec juicefs mv /mnt/jfs/.trash/<...>/<berkas> /mnt/jfs/
```
