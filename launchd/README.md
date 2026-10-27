# LaunchAgent

Dua agent untuk jalur native (tanpa Docker). **Keduanya sekarang terpasang** dan
berjalan — berbeda dari sebelumnya, ketika folder ini hanya berisi template.

| Berkas | Label | Fungsi |
|---|---|---|
| `com.juicefs.lab.mount.plist` | `com.juicefs.lab.mount` | mount JuiceFS saat login, pasang ulang kalau mati |
| `com.juicefs.lab.backup.plist` | `com.juicefs.lab.backup` | dump metadata ke `dumps/` tiap hari 12:00 |

```bash
./launchd/install.sh              # pasang / segarkan
launchctl list | grep juicefs     # status
tail -f ~/.local/share/juicefs-lab/dumps/mount.log   # log mount
tail ~/.local/share/juicefs-lab/dumps/backup.log     # log backup
```

## Agent mount

Menjalankan [`../mount-native.sh`](../mount-native.sh), disalin ke
`~/.local/share/juicefs-lab/mount-native.sh` oleh `install.sh`.

| Setelan | Nilai | Alasan |
|---|---|---|
| `RunAtLoad` | `true` | mount begitu login |
| `KeepAlive` | `true` | proses mati → launchd memasang ulang |
| `ThrottleInterval` | 30 detik | mencegah putaran cepat kalau Redis mati lama |
| Log | `~/.local/share/juicefs-lab/dumps/mount.log` | |

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
tail ~/.local/share/juicefs-lab/dumps/backup.log
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

Path ditulis absolut ke dalam plist, jadi jangan menunjuk berkas di dalam repo.
Kalau yang ditunjuk adalah berkas di repo, setiap kali folder repo dipindah,
di-rename, atau di-clone ulang, mount mati diam-diam — launchd hanya mencatat
exit 127 (`No such file or directory`) berulang di log tanpa memberi tahu
siapa pun. Itu pernah terjadi: folder lab dipindah ke `~/Documents/Code`, mount
hilang ~35 jam sebelum ketahuan.

Karena itu skrip **disalin keluar repo** ke lokasi tetap:

```
~/.local/share/juicefs-lab/
├── .env              # kredensial, mode 600, tidak pernah masuk git
├── mount-native.sh
├── backup-meta.sh
└── dumps/            # log + backup metadata
```

Repo tetap jadi sumber aslinya. Pasang atau segarkan salinannya dengan:

```bash
./launchd/install.sh
```

Skrip itu idempoten — aman dijalankan berulang. Yang dilakukannya:

1. menyalin `mount-native.sh` dan `backup-meta.sh` ke `~/.local/share/juicefs-lab/`
2. menyalin `.env` **hanya kalau belum ada**, jadi setelan lokal tidak tertimpa
3. men-`sed` placeholder `__LAB_DIR__` di template plist menjadi path runtime itu
4. `launchctl unload` lalu `load` kedua agent

Setiap kali skrip di repo diubah, jalankan ulang `install.sh` untuk menyegarkan
salinan yang dipakai launchd.

## Mencopot

```bash
./launchd/install.sh --uninstall
```

Data di `~/.local/share/juicefs-lab/` sengaja **tidak** dihapus — di situ ada
`.env` dan seluruh backup metadata. Hapus manual kalau memang tidak diperlukan.

Mencopot agent mount **tidak** melepas volume yang sedang ter-mount — jalankan
`juicefs umount ~/jfs` sesudahnya.


## Catatan

- Backup gagal keras (exit 1) kalau metadata engine tidak terjangkau, dan backup
  lama **tidak** tertimpa. Tercatat di `~/.local/share/juicefs-lab/dumps/backup.log`.
- Kalau Mac tertidur saat jadwal, launchd menjalankannya begitu Mac bangun.
