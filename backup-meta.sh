#!/usr/bin/env bash
#
# Backup metadata JuiceFS ke disk Mac — lapis kedua.
#
# Lapis pertama sudah ditangani JuiceFS sendiri (--backup-meta 1h → R2), tapi
# itu tersimpan di bucket yang SAMA dengan datanya. Kalau akun R2 bermasalah
# atau bucket terhapus, backup ikut hilang. Skrip ini menyalinnya keluar.
#
# Dijadwalkan lewat launchd: ~/Library/LaunchAgents/com.juicefs.lab.backup.plist
# Jalankan manual: ./backup-meta.sh
#
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMPS="$LAB_DIR/dumps"
LOG="$DUMPS/backup.log"
META_URL="${META_URL:-redis://redis:6379/2}"

KEEP_DAILY=7      # simpan 7 backup harian terakhir
KEEP_WEEKLY=4     # simpan 4 backup mingguan terakhir

mkdir -p "$DUMPS"
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

cd "$LAB_DIR"

# ── Pastikan container hidup ────────────────────────────────────────────
if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q '^jfs-client$'; then
  log "GAGAL: container jfs-client tidak berjalan — backup dilewati"
  exit 1
fi

STAMP="$(date '+%Y-%m-%d')"
TMP_IN_CONTAINER="/dumps/.tmp-${STAMP}.json"
TMP_ON_HOST="$DUMPS/.tmp-${STAMP}.json"
FINAL="$DUMPS/meta-${STAMP}.json.gz"

cleanup() { rm -f "$TMP_ON_HOST" "$TMP_ON_HOST.gz" 2>/dev/null || true; }
trap cleanup EXIT

# ── Dump ────────────────────────────────────────────────────────────────
if ! docker compose exec -T juicefs juicefs dump "$META_URL" "$TMP_IN_CONTAINER" >/dev/null 2>&1; then
  log "GAGAL: juicefs dump error"
  exit 1
fi

[ -s "$TMP_ON_HOST" ] || { log "GAGAL: hasil dump kosong"; exit 1; }

# ── Verifikasi JSON valid sebelum menimpa backup lama ───────────────────
if ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'FSTree' in d and 'Setting' in d else 1)" "$TMP_ON_HOST" 2>/dev/null; then
  log "GAGAL: dump tidak berisi FSTree/Setting — kemungkinan rusak, tidak disimpan"
  exit 1
fi

FILES=$(python3 -c "
import json,sys
def count(n):
    t=0
    if isinstance(n,dict):
        for k,v in n.items():
            if k=='entries' and isinstance(v,dict): t+=len(v)
            t+=count(v)
    elif isinstance(n,list):
        for v in n: t+=count(v)
    return t
print(count(json.load(open(sys.argv[1])).get('FSTree',{})))
" "$TMP_ON_HOST" 2>/dev/null || echo "?")

gzip -f "$TMP_ON_HOST"
mv -f "$TMP_ON_HOST.gz" "$FINAL"
SIZE=$(/usr/bin/du -h "$FINAL" | cut -f1 | tr -d ' ')
log "OK  $(basename "$FINAL")  ${SIZE}  (~${FILES} entri)"

# ── Salinan mingguan tiap Minggu ────────────────────────────────────────
if [ "$(date '+%u')" = "7" ]; then
  cp -f "$FINAL" "$DUMPS/weekly-${STAMP}.json.gz"
  log "    salinan mingguan dibuat"
fi

# ── Rotasi ──────────────────────────────────────────────────────────────
rotate() {
  local pattern="$1" keep="$2" n
  # shellcheck disable=SC2012
  n=$(ls -1t "$DUMPS"/${pattern} 2>/dev/null | tail -n "+$((keep+1))" || true)
  if [ -n "$n" ]; then
    echo "$n" | while read -r f; do rm -f "$f" && log "    rotasi: hapus $(basename "$f")"; done
  fi
}
rotate 'meta-*.json.gz'   "$KEEP_DAILY"
rotate 'weekly-*.json.gz' "$KEEP_WEEKLY"

TOTAL=$(/usr/bin/du -sh "$DUMPS" 2>/dev/null | cut -f1 | tr -d ' ')
log "    total folder dumps: $TOTAL"
