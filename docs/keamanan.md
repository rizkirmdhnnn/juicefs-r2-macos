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

### Mengganti user atau password SMB

`.env` adalah satu-satunya tempat yang perlu disentuh. Akun Samba dibangun
ulang dari `SMB_USER`/`SMB_PASSWORD` tiap container start, dan passdb-nya ada
di layer container (bukan volume), jadi akun lama ikut hilang sendiri saat
recreate — tidak ada yang perlu dibersihkan manual di dalam container.

```bash
cd ~/juicefs-lab

# 1. Lepas mount dulu, selama masih memakai kredensial lama
umount ~/mnt/jfs

# 2. Buang entri Keychain lama
security delete-internet-password -s jfs-client.orb.local

# 3. Ubah SMB_USER / SMB_PASSWORD
$EDITOR .env

# 4. Recreate container
docker compose up -d
```

Lalu mount kembali seperti biasa.

**Langkah 2 adalah yang paling sering terlewat.** Keychain macOS menyimpan
kredensial SMB per host dan tidak ikut berubah saat `.env` diubah. Kalau entri
lama dibiarkan, Finder diam-diam mengirimkan username lama dan kamu mendapat
penolakan autentikasi meski `.env` sudah benar — gejalanya mengarahkan dugaan
ke container, padahal sumbernya ada di Mac.

**Gunakan `up -d`, bukan `restart`.** Variabel environment dibekukan saat
container dibuat, jadi `docker compose restart` menjalankan ulang entrypoint
dengan `SMB_USER` yang lama dan membuat perubahan `.env` seolah tidak
berpengaruh. `up -d` mendeteksi perubahan config lalu me-recreate — dan
recreate itulah yang sekalian menghapus passdb lama.

`--build` hanya perlu kalau yang diubah `entrypoint.sh`, `smb.conf`, atau
`Dockerfile`, karena ketiganya di-`COPY` ke dalam image. Untuk perubahan `.env`
saja, `up -d` sudah cukup.

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
