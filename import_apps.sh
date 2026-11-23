#!/usr/bin/env bash
# import_apps.sh — copia i moduli Odoo scompattati da una cartella sorgente in repos_apps,
# verifica la copia e cancella l'originale solo se la copia è identica.
#
#   sudo ./import_apps.sh                  usa i default
#   sudo ./import_apps.sh -n               simulazione: mostra cosa farebbe, non tocca nulla
#   sudo ./import_apps.sh -s SRC -d DST    cartelle personalizzate
#
# Regole:
#  - si copia solo una cartella che contiene __manifest__.py (un modulo Odoo)
#  - se in DST esiste già una cartella con lo stesso nome non si sovrascrive: la sorgente resta
#  - file e cartelle che non sono moduli (zip, README, ecc.) non vengono toccati
set -euo pipefail

SRC="/home/ammstanc/addon"
DST="/home/odoo/addons/repos_apps"
OWNER="odoo"
DRY=0

log()  { printf '%s\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

while getopts ":s:d:nh" opt; do
    case "$opt" in
        s) SRC="$OPTARG" ;;
        d) DST="$OPTARG" ;;
        n) DRY=1 ;;
        h) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        :) die "manca il valore per -$OPTARG" ;;
        *) die "opzione sconosciuta: -$OPTARG" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "esegui con sudo"
[ -d "$SRC" ] || die "cartella sorgente non trovata: $SRC"
id "$OWNER" >/dev/null 2>&1 || die "utente '$OWNER' non trovato"

SRC="$(realpath "$SRC")"
DST="$(realpath -m "$DST")"
cd /

if [ "$DRY" -eq 0 ]; then
    install -d -o "$OWNER" -g "$OWNER" -m 755 "$DST"
fi

log "Sorgente: $SRC"
log "Destinazione: $DST$([ "$DRY" -eq 1 ] && echo '  (simulazione)')"
log ""

copied=0; skipped=0; failed=0
shopt -s nullglob
for dir in "$SRC"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"

    if [ -L "$dir" ]; then
        warn "$name: è un link simbolico, lo salto"
        skipped=$((skipped + 1)); continue
    fi
    if [ ! -f "$dir/__manifest__.py" ]; then
        warn "$name: nessun __manifest__.py, non è un modulo Odoo: lo salto"
        skipped=$((skipped + 1)); continue
    fi
    if [ -e "$DST/$name" ] || [ -L "$DST/$name" ]; then
        warn "$name: già presente in destinazione, non sovrascrivo (resta in $SRC)"
        skipped=$((skipped + 1)); continue
    fi

    if [ "$DRY" -eq 1 ]; then
        ok "[simulazione] $name → $DST/$name"
        copied=$((copied + 1)); continue
    fi

    # 1. copia   2. verifica identità   3. proprietà   4. cancellazione dell'originale
    if ! cp -a -- "$dir" "$DST/$name"; then
        warn "$name: copia fallita"
        rm -rf -- "$DST/$name"
        failed=$((failed + 1)); continue
    fi
    if ! diff -rq -- "$dir" "$DST/$name" >/dev/null; then
        warn "$name: la copia non corrisponde all'originale, originale conservato"
        rm -rf -- "$DST/$name"
        failed=$((failed + 1)); continue
    fi
    chown -R "$OWNER:$OWNER" "$DST/$name"
    chmod -R a+rX "$DST/$name"
    rm -rf -- "$dir"
    ok "$name: copiato e rimosso da $SRC"
    copied=$((copied + 1))
done

log ""
log "Copiati: $copied · saltati: $skipped · errori: $failed"
if [ "$DRY" -eq 0 ] && [ "$copied" -gt 0 ]; then
    log "Per attivarli in Odoo: sudo ./stack.sh addon sync  (oppure modules.txt + sync)"
fi
[ "$failed" -eq 0 ] || exit 1
