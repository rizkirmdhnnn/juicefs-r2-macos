# LaunchAgent

Dua agent untuk jalur native (tanpa Docker). **Keduanya sekarang terpasang** dan
berjalan — berbeda dari sebelumnya, ketika folder ini hanya berisi template.

| Berkas | Label | Fungsi |
|---|---|---|
| `com.juicefs.lab.mount.plist` | `com.juicefs.lab.mount` | mount JuiceFS saat login, pasang ulang kalau mati |
| `com.juicefs.lab.backup.plist` | `com.juicefs.lab.backup` | dump metadata ke `dumps/` tiap hari 12:00 |

```bash
launchctl list | grep juicefs     # status
tail -f ../dumps/mount.log        # log mount
tail ../dumps/backup.log          # log backup
```

## Agent mount

Menjalankan [`../mount-native.sh`](../mount-native.sh).

| Setelan | Nilai | Alasan |
|---|---|---|
| `RunAtLoad` | `true` | mount begitu login |
| `KeepAlive` | `true` | proses mati → launchd memasang ulang |
| `ThrottleInterval` | 30 detik | mencegah putaran cepat kalau Redis mati lama |
| Log | `dumps/mount.log` | |

Dua hal yang membuatnya bekerja:

- **Foreground.** `mount-native.sh` memanggil `juicefs mount` **tanpa**
  `--background`. Kalau prosesnya daemonize, launchd melihatnya langsung selesai
  lalu menghidupkannya berulang-ulang.
- **Menunggu Redis.** Skrip menunggu sampai 60 detik sebelum menyerah.
  `brew services` (Redis) dan agent ini sama-sama jalan saat login, dan launchd
  tidak menjamin urutannya.

Diuji: `juicefs umount ~/jfs` → dipasang ulang otomatis dalam 17 detik.

## Agent backup

Menjalankan [`../backup-meta.sh`](../backup-meta.sh) tiap hari pukul 12:00.
`RunAtLoad` sengaja `false` — tidak ikut jalan saat di-`load`.

Dulu agent ini **tidak** dipasang, karena container membuat dump tiap kali
berhenti (`BACKUP_ON_STOP`). Setelah pindah ke native, mekanisme itu tidak punya
pengganti, jadi agent ini jadi satu-satunya lapis backup ke disk lokal.

Uji tanpa menunggu jadwal:

```bash
launchctl start com.juicefs.lab.backup
tail dumps/backup.log
```

## Mengubah jadwal

Edit `StartCalendarInterval` di plist, lalu pasang ulang — launchd tidak membaca
perubahan berkas secara otomatis.

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

## Memasang ulang

Path ditulis absolut ke dalam plist, jadi setiap kali folder lab dipindahkan
atau plist diedit:

```bash
cd ~/juicefs-lab
for f in mount backup; do
  sed "s|__LAB_DIR__|$PWD|g" "launchd/com.juicefs.lab.$f.plist" \
    > ~/Library/LaunchAgents/com.juicefs.lab.$f.plist
  plutil -lint ~/Library/LaunchAgents/com.juicefs.lab.$f.plist
  launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.$f.plist 2>/dev/null
  launchctl load   ~/Library/LaunchAgents/com.juicefs.lab.$f.plist
done
```

## Mencopot

```bash
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.mount.plist
launchctl unload ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
rm ~/Library/LaunchAgents/com.juicefs.lab.{mount,backup}.plist
```

Mencopot agent mount **tidak** melepas volume yang sedang ter-mount — jalankan
`juicefs umount ~/jfs` sesudahnya.


## Catatan

- Backup gagal keras (exit 1) kalau metadata engine tidak terjangkau, dan backup
  lama **tidak** tertimpa. Tercatat di `dumps/backup.log`.
- Kalau Mac tertidur saat jadwal, launchd menjalankannya begitu Mac bangun.
