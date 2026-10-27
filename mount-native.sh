#!/usr/bin/env bash
#
# Mount JuiceFS langsung di macOS lewat macFUSE — tanpa Docker.
#
# Dijalankan di FOREGROUND supaya bisa diawasi launchd. Jangan tambahkan
# `--background`: kalau prosesnya daemonize, launchd melihatnya langsung
# selesai lalu menghidupkannya berulang-ulang.
#
# Manual : ./mount-native.sh
# Otomatis: ~/Library/LaunchAgents/com.juicefs.lab.mount.plist
#
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# launchd memberi PATH minimal — Homebrew tidak ikut.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH

# Ambil setelan dari .env kalau ada, tapi jangan sampai variabel yang tidak
# ada bikin `set -u` menghentikan skrip.
if [ -f "$LAB_DIR/.env" ]; then
  set -a; . "$LAB_DIR/.env"; set +a
fi

META_URL="${META_URL_NATIVE:-redis://127.0.0.1:6379/2}"
MOUNTPOINT="${MOUNTPOINT:-$HOME/jfs}"
CACHE_DIR="${CACHE_DIR:-$HOME/Library/Caches/JuiceFS}"
CACHE_SIZE="${CACHE_SIZE:-10240}"
BUFFER_SIZE="${BUFFER_SIZE:-300}"
MAX_DOWNLOADS="${MAX_DOWNLOADS:-32}"
MAX_UPLOADS="${MAX_UPLOADS:-20}"
BACKUP_META="${BACKUP_META:-1h}"
VOLNAME="${VOLNAME:-JuiceFS}"

mkdir -p "$MOUNTPOINT" "$CACHE_DIR"

# ── Tunggu Redis ────────────────────────────────────────────────────────
# `brew services` menghidupkan Redis saat login juga, dan launchd tidak
# menjamin urutannya. Tanpa penantian ini, mount gagal dengan
# "connection refused" pada login yang Redis-nya kebetulan telat siap.
for i in $(seq 1 60); do
  if juicefs status "$META_URL" >/dev/null 2>&1; then break; fi
  if [ "$i" = 60 ]; then
    echo "GAGAL: metadata engine tidak terjangkau di $META_URL setelah 60 detik" >&2
    exit 1
  fi
  sleep 1
done

# Kalau sudah ter-mount (mis. agent dihidupkan ulang tanpa logout), jangan
# menumpuk mount di atas mount.
if mount | grep -q " $MOUNTPOINT "; then
  echo "sudah ter-mount di $MOUNTPOINT, tidak melakukan apa-apa" >&2
  exit 0
fi

# ── Mount ───────────────────────────────────────────────────────────────
# -o local       → Finder memperlakukannya sebagai disk (muncul di sidebar)
# --enable-xattr → macOS menyimpan xattr secara native, jadi Finder tidak perlu
#                  membuat berkas AppleDouble (._*) sama sekali
# --backup-meta  → dump metadata berkala ke R2; dulu tugas container
#
# JANGAN tambahkan `noappledouble`. Opsi itu tidak cuma memblokir ._*, tapi juga
# .DS_Store — dan Finder memperlakukan penolakan itu sebagai kegagalan fatal:
# menyalin folder berhenti dengan "error code -8062". Lihat
# docs/temuan-teknis.md.
exec juicefs mount "$META_URL" "$MOUNTPOINT" \
  --cache-dir "$CACHE_DIR" \
  --cache-size "$CACHE_SIZE" \
  --buffer-size "$BUFFER_SIZE" \
  --max-downloads "$MAX_DOWNLOADS" \
  --max-uploads "$MAX_UPLOADS" \
  --enable-xattr \
  --backup-meta "$BACKUP_META" \
  -o "volname=$VOLNAME,local"
