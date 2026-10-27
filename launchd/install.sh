#!/usr/bin/env bash
#
# Pasang (atau perbarui) LaunchAgent JuiceFS untuk jalur native macOS.
#
# Kenapa skrip disalin keluar dari repo:
#   launchd menyimpan path ABSOLUT di dalam plist. Kalau yang ditunjuk adalah
#   berkas di dalam repo, setiap kali folder repo dipindah, di-rename, atau
#   di-clone ulang, mount mati diam-diam — launchd cuma mencatat exit 127
#   ("No such file or directory") berulang di log, tanpa ada yang memberi tahu.
#   Itu persis yang terjadi saat folder lab dipindah ke ~/Documents/Code.
#
#   Jadi berkas yang dijalankan launchd disalin ke lokasi tetap di luar repo:
#       ~/.local/share/juicefs-lab/
#   Repo tetap jadi sumber aslinya. Setiap kali skrip di repo diubah, jalankan
#   ulang skrip ini untuk menyegarkan salinannya.
#
# Pemakaian:
#   ./launchd/install.sh            # pasang / perbarui
#   ./launchd/install.sh --uninstall
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$HOME/.local/share/juicefs-lab"
AGENTS="$HOME/Library/LaunchAgents"
LABELS=(mount backup)

die() { printf 'GAGAL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# ── Copot ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
  for label in "${LABELS[@]}"; do
    plist="$AGENTS/com.juicefs.lab.$label.plist"
    if [ -f "$plist" ]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      say "dicopot: com.juicefs.lab.$label"
    fi
  done
  say ""
  say "Catatan: mencopot agent mount TIDAK melepas volume yang sedang ter-mount."
  say "Jalankan sendiri kalau perlu:  juicefs umount ~/jfs"
  say "Data di $RUNTIME sengaja TIDAK dihapus (berisi .env dan backup metadata)."
  exit 0
fi

# ── Prasyarat ───────────────────────────────────────────────────────────
command -v juicefs >/dev/null 2>&1 \
  || die "juicefs tidak ada di PATH. Pasang dulu: brew install juicefs"
[ -f "$REPO_DIR/.env" ] \
  || die ".env tidak ada di $REPO_DIR — salin dari .env.example lalu isi kredensial"

# ── Salin berkas runtime ke lokasi tetap ────────────────────────────────
say "→ menyiapkan $RUNTIME"
mkdir -p "$RUNTIME/dumps"

# Skrip diletakkan langsung di $RUNTIME (bukan subfolder), karena di dalam
# skrip ada `LAB_DIR="$(cd "$(dirname "$0")" && pwd)"` — LAB_DIR harus menunjuk
# folder yang juga berisi .env dan dumps/.
for f in mount-native.sh backup-meta.sh; do
  [ -f "$REPO_DIR/$f" ] || die "$f tidak ada di repo"
  cp "$REPO_DIR/$f" "$RUNTIME/$f"
  chmod +x "$RUNTIME/$f"
done

# .env berisi kredensial R2 — hanya disalin kalau belum ada, supaya setelan
# lokal yang sudah disesuaikan tidak tertimpa saat install diulang.
if [ -f "$RUNTIME/.env" ]; then
  say "  .env sudah ada, tidak ditimpa"
else
  cp "$REPO_DIR/.env" "$RUNTIME/.env"
  say "  .env disalin"
fi
chmod 600 "$RUNTIME/.env"

# ── Pasang plist ────────────────────────────────────────────────────────
# Path di plist menunjuk $RUNTIME (stabil), bukan $REPO_DIR.
for label in "${LABELS[@]}"; do
  src="$REPO_DIR/launchd/com.juicefs.lab.$label.plist"
  dst="$AGENTS/com.juicefs.lab.$label.plist"

  [ -f "$src" ] || die "template tidak ada: $src"

  sed "s|__LAB_DIR__|$RUNTIME|g" "$src" > "$dst"
  plutil -lint "$dst" >/dev/null || die "plist tidak valid: $dst"

  # unload dulu supaya launchd membaca ulang berkasnya — ia tidak memantau
  # perubahan plist. `|| true` karena unload gagal kalau agent belum terpasang.
  launchctl unload "$dst" 2>/dev/null || true
  launchctl load "$dst" 2>/dev/null || die "launchctl load gagal: $dst"
  say "→ terpasang: com.juicefs.lab.$label"
done

# ── Verifikasi ──────────────────────────────────────────────────────────
say ""
say "Status:"
launchctl list | grep 'com\.juicefs\.lab' || say "  (belum terlihat — coba cek beberapa detik lagi)"

say ""
say "Agent mount berjalan di foreground, jadi butuh beberapa detik."
say "Pantau dengan:  tail -f $RUNTIME/dumps/mount.log"
say "Cek mount   :  mount | grep jfs"
