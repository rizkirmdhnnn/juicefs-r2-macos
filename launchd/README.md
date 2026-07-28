# Penjadwalan backup metadata (belum dipasang)

`com.juicefs.lab.backup.plist` ada di sini sebagai **template siap pakai**.
Agent ini **belum terpasang** di sistem — tidak ada yang berjalan otomatis.

Backup manual tetap bisa kapan saja:

```bash
cd ~/juicefs-lab && ./backup-meta.sh
```

## Isi plist saat ini

| Setelan | Nilai |
|---|---|
| Label | `com.juicefs.lab.backup` |
| Jadwal | tiap hari **12:00** |
| Perintah | `/bin/bash ~/juicefs-lab/backup-meta.sh` |
| Log | `~/juicefs-lab/dumps/launchd.log` |
| `RunAtLoad` | `false` — tidak langsung jalan saat di-load |
| `PATH` | menyertakan `/usr/local/bin` (docker CLI OrbStack) |

## Kalau nanti mau dipasang

```bash
cd ~/juicefs-lab

# 1. Salin ke LaunchAgents (launchd hanya membaca dari sana)
cp launchd/com.juicefs.lab.backup.plist ~/Library/LaunchAgents/

# 2. Validasi
plutil -lint ~/Library/LaunchAgents/com.juicefs.lab.backup.plist

# 3. Aktifkan
launchctl load ~/Library/LaunchAgents/com.juicefs.lab.backup.plist

# 4. Pastikan terdaftar
launchctl list | grep juicefs

# 5. Uji tanpa menunggu jadwal
launchctl start com.juicefs.lab.backup
tail dumps/launchd.log
```

## Mencopot kembali

```bash
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
rm ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
```

## Mengubah jadwal

Edit `StartCalendarInterval` di plist. Kalau agent sudah terpasang, salin ulang
lalu `unload` + `load` — launchd tidak membaca perubahan file secara otomatis.

```xml
<!-- tiap hari 02:00 -->
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key><integer>2</integer>
    <key>Minute</key><integer>0</integer>
</dict>

<!-- tiap Minggu 12:00 (Weekday: 0=Minggu) -->
<key>StartCalendarInterval</key>
<dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>12</integer>
    <key>Minute</key><integer>0</integer>
</dict>
```

## Catatan

- Path di plist **absolut** (`/Users/rizkirmdhn/juicefs-lab/...`). Kalau folder
  lab dipindah, sesuaikan dulu.
- Jadwal akan gagal kalau OrbStack belum menyala saat itu. Kegagalan tercatat
  di `dumps/backup.log` dengan `exit code 1`, dan backup lama tidak tertimpa.
- Kalau Mac tertidur saat jadwal, launchd menjalankannya begitu Mac bangun.
- Alternatif tanpa launchd: panggil `backup-meta.sh` dari cron, dari skrip
  lain, atau jalankan manual sesekali.
