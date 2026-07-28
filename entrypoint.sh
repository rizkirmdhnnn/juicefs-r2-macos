#!/usr/bin/env bash
#
# Entrypoint container jfs-client.
#   1. format volume JuiceFS di R2 (sekali saja)
#   2. mount lewat FUSE
#   3. jalankan WebDAV + Samba supaya bisa diakses dari Finder macOS
#   4. tunggu sinyal, lalu berhenti dengan bersih
#
set -euo pipefail

# ── Konfigurasi (semua bisa ditimpa lewat environment di compose) ────────
META_URL="${META_URL:-redis://redis:6379/2}"
VOL_NAME="${VOL_NAME:-myjfs-r2}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/jfs}"
CACHE_DIR="${CACHE_DIR:-/var/jfsCache}"
CACHE_SIZE="${CACHE_SIZE:-10240}"
TRASH_DAYS="${TRASH_DAYS:-1}"
BACKUP_META="${BACKUP_META:-1h}"
WEBDAV_ADDR="${WEBDAV_ADDR:-0.0.0.0:9007}"

# Saklar layanan. SMB adalah jalur utama ke Finder macOS; WebDAV disimpan
# sebagai cadangan dan default-nya mati supaya tidak ada proses menganggur.
ENABLE_SMB="${ENABLE_SMB:-true}"
ENABLE_WEBDAV="${ENABLE_WEBDAV:-false}"

# Dump metadata ke /dumps (disk Mac) tiap kali container berhenti dengan
# bersih — menutup jendela antara backup otomatis terakhir dan saat mati.
BACKUP_ON_STOP="${BACKUP_ON_STOP:-true}"
KEEP_SHUTDOWN_DUMPS="${KEEP_SHUTDOWN_DUMPS:-5}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Terima true/1/yes/on (huruf besar-kecil bebas) sebagai "menyala"
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
    *)             return 1 ;;
  esac
}

require_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v belum diisi — cek file .env"
  done
}

# ── Endpoint R2 ─────────────────────────────────────────────────────────
r2_endpoint() {
  if [ -n "${R2_JURISDICTION:-}" ]; then
    printf '%s.%s.r2.cloudflarestorage.com' "$R2_ACCOUNT_ID" "$R2_JURISDICTION"
  else
    printf '%s.r2.cloudflarestorage.com' "$R2_ACCOUNT_ID"
  fi
}

# ── 1. Format (hanya kalau volume belum ada) ────────────────────────────
format_if_needed() {
  if juicefs status "$META_URL" >/dev/null 2>&1; then
    log "Volume sudah ada — lanjut mount"
    return
  fi

  local host; host="$(r2_endpoint)"
  log "Format volume baru: $VOL_NAME  →  $host/$R2_BUCKET"
  juicefs format \
    --storage s3 \
    --bucket "https://${host}/${R2_BUCKET}" \
    --access-key "$R2_ACCESS_KEY" \
    --secret-key "$R2_SECRET_KEY" \
    --trash-days "$TRASH_DAYS" \
    "$META_URL" "$VOL_NAME"
}

# ── 1b. Terapkan TRASH_DAYS ke volume yang sudah ada ────────────────────
#
# --trash-days hanya berlaku saat `juicefs format`. Tanpa fungsi ini,
# mengubah TRASH_DAYS di .env tidak berpengaruh apa-apa pada volume lama —
# diam-diam diabaikan, yang jauh lebih membingungkan daripada error.
apply_trash_days() {
  local current
  current="$(juicefs status "$META_URL" 2>/dev/null \
    | grep -o '"TrashDays"[[:space:]]*:[[:space:]]*[0-9]*' \
    | grep -o '[0-9]*$' || true)"

  if [ -z "$current" ]; then
    warn "tidak bisa membaca TrashDays saat ini — dilewati"
    return
  fi

  if [ "$current" = "$TRASH_DAYS" ]; then
    log "Trash: $TRASH_DAYS hari"
    return
  fi

  log "Trash: ubah $current → $TRASH_DAYS hari"
  juicefs config "$META_URL" --trash-days "$TRASH_DAYS" >/dev/null
  if [ "$TRASH_DAYS" = "0" ]; then
    warn "TRASH_DAYS=0 → trash MATI. File terhapus hilang permanen,"
    warn "tanpa cara memulihkan. Tidak disarankan."
  fi
}

# ── 2. Mount FUSE ───────────────────────────────────────────────────────
#
# --enable-xattr  : WAJIB untuk Samba. Modul streams_xattr menyimpan metadata
#                   macOS sebagai xattr. Tanpa ini Samba membuat file
#                   "._namafile" sungguhan yang mengotori storage dan
#                   memboroskan operasi Class A di R2.
#
# --backup-meta   : backup metadata otomatis ke R2. Dokumentasi JuiceFS
#                   menyuruh mematikannya di R2 (--backup-meta 0), tapi itu
#                   sudah usang — PR #6389 (merged 2025-09-26) membuat
#                   backup/gc/fsck/destroy bekerja dengan daftar tak terurut,
#                   dan fix itu sudah masuk v1.4.0. Diverifikasi di lab ini.
mount_juicefs() {
  log "Mount $VOL_NAME di $MOUNT_POINT"
  mkdir -p "$MOUNT_POINT"
  juicefs mount "$META_URL" "$MOUNT_POINT" \
    --cache-dir "$CACHE_DIR" \
    --cache-size "$CACHE_SIZE" \
    --backup-meta "$BACKUP_META" \
    --enable-xattr \
    --background
}

# ── 3a. WebDAV (cadangan, default MATI) ─────────────────────────────────
#
# Dimatikan karena SMB sudah menangani akses Finder dengan lebih baik.
# Hidupkan lewat .env: ENABLE_WEBDAV=true
#
# Catatan: Finder macOS pernah menghapus seluruh isi volume lewat WebDAV di
# lab ini (terselamatkan .trash). Pakai untuk baca/unduh saja, jangan untuk
# menulis file besar.
#
# --enable-proppatch dibutuhkan agar Finder macOS mau menulis.
start_webdav() {
  if ! is_true "$ENABLE_WEBDAV"; then
    log "WebDAV dilewati (ENABLE_WEBDAV=$ENABLE_WEBDAV)"
    return
  fi
  log "Start WebDAV di $WEBDAV_ADDR"
  juicefs webdav "$META_URL" "$WEBDAV_ADDR" \
    --enable-proppatch \
    --cache-dir "$CACHE_DIR" \
    --cache-size "$CACHE_SIZE" \
    --backup-meta 0 \
    --background
}

# ── 3b. Samba (jalur utama Finder) ──────────────────────────────────────
start_samba() {
  if ! is_true "$ENABLE_SMB"; then
    log "Samba dilewati (ENABLE_SMB=$ENABLE_SMB)"
    return
  fi
  log "Start Samba (share: jfs, user: $SMB_USER)"
  id -u "$SMB_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SMB_USER"
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$SMB_USER" >/dev/null
  mkdir -p /var/log/samba /run/samba
  testparm -s >/dev/null 2>&1 || { testparm -s; die "smb.conf tidak valid"; }
  smbd --daemon
}

# ── 4. Berhenti dengan bersih ───────────────────────────────────────────
#
# Tanpa ini, `docker compose down` mengirim SIGTERM ke `tail` yang tidak
# melakukan apa-apa, lalu SIGKILL. Data yang masih di buffer tulis dan belum
# terunggah ke R2 akan HILANG. Fungsi ini melepas mount lebih dulu sehingga
# JuiceFS menuntaskan flush-nya.
graceful_shutdown() {
  log "Sinyal berhenti diterima — melepas mount dengan bersih"
  pkill -TERM smbd 2>/dev/null || true
  juicefs umount "$MOUNT_POINT" 2>/dev/null \
    || umount "$MOUNT_POINT" 2>/dev/null \
    || warn "mount sudah lepas / tidak bisa dilepas"

  dump_on_shutdown
  log "Selesai"
  exit 0
}

# Dump metadata saat container berhenti.
#
# Kenapa perlu: --backup-meta hanya berjalan tiap $BACKUP_META (default 1 jam).
# Kalau container dimatikan 59 menit setelah backup terakhir, perubahan
# metadata di jendela itu cuma ada di Redis. Selama volume redis-data utuh
# tidak masalah, tapi kalau rusak atau kena `down -v`, perubahan itu hilang.
#
# Dijalankan SETELAH umount supaya menangkap kondisi final — termasuk data
# yang baru saja di-flush ke R2. `juicefs dump` bicara langsung ke Redis,
# jadi tidak butuh mount.
dump_on_shutdown() {
  is_true "$BACKUP_ON_STOP" || { log "Dump saat berhenti dilewati (BACKUP_ON_STOP=$BACKUP_ON_STOP)"; return 0; }

  local out="/dumps/shutdown-$(date '+%Y%m%d-%H%M%S').json"

  # timeout: jangan sampai menahan shutdown melebihi stop_grace_period
  if timeout 60 juicefs dump "$META_URL" "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    gzip -f "$out" 2>/dev/null || true
    log "Metadata di-dump: $(basename "$out").gz"
  else
    rm -f "$out" 2>/dev/null || true
    warn "dump saat berhenti gagal — Redis mungkin sudah berhenti duluan"
    return 0
  fi

  # Rotasi: simpan $KEEP_SHUTDOWN_DUMPS terbaru saja
  ls -1t /dumps/shutdown-*.json.gz 2>/dev/null \
    | tail -n "+$((KEEP_SHUTDOWN_DUMPS + 1))" \
    | while read -r f; do rm -f "$f"; done
}

banner() {
  local smb_line webdav_line
  if is_true "$ENABLE_SMB"; then
    smb_line="smb://jfs-client.orb.local/jfs  (user: $SMB_USER)"
  else
    smb_line="mati  (ENABLE_SMB=true untuk menyalakan)"
  fi
  if is_true "$ENABLE_WEBDAV"; then
    webdav_line="http://jfs-client.orb.local:9007 (user: $WEBDAV_USER)"
  else
    webdav_line="mati  (ENABLE_WEBDAV=true untuk menyalakan)"
  fi

  cat <<EOF

==================================================
 JuiceFS siap
   Mount   : $MOUNT_POINT
   Meta    : $META_URL
   Trash   : $TRASH_DAYS hari
   Backup  : tiap $BACKUP_META ke R2 + saat berhenti ke /dumps
   SMB     : $smb_line
   WebDAV  : $webdav_line
==================================================
EOF
  df -h "$MOUNT_POINT" | tail -1
  echo
}

main() {
  require_env R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY R2_SECRET_KEY

  # if eksplisit, bukan `&&` — di bawah `set -e` rantai && yang gagal di
  # bagian awal bisa menghentikan skrip secara tak sengaja.
  if is_true "$ENABLE_SMB"; then
    require_env SMB_USER SMB_PASSWORD
  fi
  if is_true "$ENABLE_WEBDAV"; then
    require_env WEBDAV_USER WEBDAV_PASSWORD
  fi

  trap graceful_shutdown TERM INT

  format_if_needed
  apply_trash_days
  mount_juicefs
  start_webdav
  start_samba
  banner

  # `sleep infinity & wait` — bukan `tail -f /dev/null` — supaya trap di atas
  # benar-benar terpanggil saat container dihentikan.
  sleep infinity &
  wait $!
}

main "$@"
