#!/usr/bin/env bash
# git_repos.sh — clona e aggiorna repository git a profondità 1 (single-branch).
#
#   git_repos.sh clone   -f repos.txt [-d DIR]     clona i mancanti; rifà il clone se branch/origine sono cambiati
#   git_repos.sh update  -f repos.txt [-d DIR]     aggiorna quelli già presenti (fetch --depth 1 + reset)
#   git_repos.sh install -f repos.txt [-d DIR] [-auto yes|no]
#                                                  -auto yes: installa il cron settimanale (domenica 03:00)
#                                                  -auto no (o omesso): nessun cron, uso manuale
#
# Formato di repos.txt, una riga per repository:
#   owner/repo  branch          es. OCA/web 18.0
#   URL         branch          es. https://github.com/OCA/server-tools.git 18.0
#   # le righe che iniziano con # (o con un commento dopo il branch) sono ignorate
#
# Variabili utili: OWNER (utente che possiede i repository, default odoo),
#                  CRON_FILE, LOG_FILE, LOCK_FILE (per test o personalizzazioni).
set -euo pipefail

SELF="$(realpath "$0")"
DEST_DEFAULT=/home/odoo/addons/repos_git
OWNER="${OWNER:-odoo}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/git-repos-update}"
LOG_FILE="${LOG_FILE:-/var/log/git_repos.log}"
LOCK_FILE="${LOCK_FILE:-/run/git_repos.lock}"

log()  { printf '%s\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

# ── Esecuzione git: come OWNER quando lo script gira come root ───────────────
owner_home() { getent passwd "$1" | cut -d: -f6; }

run_git() {
    if [ "$(id -u)" -eq 0 ] && id "$OWNER" >/dev/null 2>&1; then
        runuser -u "$OWNER" -- env HOME="$(owner_home "$OWNER")" git "$@"
    else
        git "$@"
    fi
}

# ── Lettura di repos.txt → righe "nome<TAB>url<TAB>branch" ───────────────────
parse_list() {
    local file="$1" line a b url name lineno=0
    declare -A seen=()
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"          # file salvati su Windows: togli il CR finale
        line="${line%%#*}"
        read -r a b _ <<< "$line" || true
        [ -n "${a:-}" ] || continue
        [ -n "${b:-}" ] || die "$file:$lineno: manca il branch (formato: owner/repo branch)"
        if [[ "$a" == *://* || "$a" == git@* || "$a" == /* ]]; then
            url="$a"
        elif [[ "$a" == */* ]]; then
            url="https://github.com/${a%.git}.git"
        else
            die "$file:$lineno: '$a' non è né owner/repo né un URL"
        fi
        name="$(basename "${url%.git}")"
        [ -z "${seen[$name]:-}" ] || die "$file:$lineno: il repository '$name' è già in lista"
        seen[$name]=1
        printf '%s\t%s\t%s\n' "$name" "$url" "$b"
    done < "$file"
}

# ── Operazione su un singolo repository ──────────────────────────────────────
# sync_one <clone|update> <nome> <url> <branch> <dst>   → 0 ok, 1 errore
# Nota: dentro "cmd || ..." set -e è disattivato, quindi ogni comando git controlla il proprio errore.
sync_one() {
    local mode="$1" name="$2" url="$3" branch="$4" dst="$5"

    if [ -e "$dst" ] && [ ! -d "$dst/.git" ]; then
        warn "$name: $dst esiste ma non è un repository git, lo lascio com'è"
        return 1
    fi

    if [ -d "$dst/.git" ]; then
        local cur origin
        cur="$(run_git -C "$dst" rev-parse --abbrev-ref HEAD)" || return 1
        origin="$(run_git -C "$dst" config --get remote.origin.url || true)"
        if [ "$cur" != "$branch" ] || [ "$origin" != "$url" ]; then
            warn "$name: branch o origine cambiati ($cur → $branch), rifaccio il clone"
            rm -rf "$dst" || { warn "$name: impossibile rimuovere $dst"; return 1; }
        else
            if [ "$mode" = clone ]; then
                ok "$name: già presente ($branch), salto. Usa 'update' per aggiornarlo"
                return 0
            fi
            local before after dirty
            before="$(run_git -C "$dst" rev-parse --short HEAD)" || return 1
            dirty="$(run_git -C "$dst" status --porcelain)" || return 1
            run_git -C "$dst" fetch --depth 1 --quiet origin "$branch" || { warn "$name: fetch fallito"; return 1; }
            run_git -C "$dst" reset --hard --quiet FETCH_HEAD || return 1
            run_git -C "$dst" clean -ffdq || return 1
            after="$(run_git -C "$dst" rev-parse --short HEAD)" || return 1
            if [ -n "$dirty" ]; then
                warn "$name: scartate modifiche locali ($(printf '%s\n' "$dirty" | wc -l) voci): usa un modulo custom per le modifiche"
            fi
            if [ "$before" = "$after" ]; then ok "$name: già aggiornato ($branch @ $after)"
            else ok "$name: aggiornato ($branch $before → $after)"; fi
            return 0
        fi
    else
        if [ "$mode" = update ]; then
            warn "$name: non presente in $dst, uso 'clone' per scaricarlo"
            return 1
        fi
    fi

    install -d -o "$OWNER" -g "$OWNER" -m 755 "$(dirname "$dst")" 2>/dev/null || mkdir -p "$(dirname "$dst")"
    if ! run_git clone --depth 1 --single-branch --branch "$branch" --quiet -- "$url" "$dst"; then
        warn "$name: clone fallito (controlla URL e branch '$branch')"
        return 1
    fi
    ok "$name: clonato ($branch)"
}

# ── Comandi ──────────────────────────────────────────────────────────────────
run_list() {
    local mode="$1" file="$2" dest="$3"
    [ -f "$file" ] || die "file non trovato: $file"
    install -d -m 755 "$dest" 2>/dev/null || mkdir -p "$dest"
    if [ "$(id -u)" -eq 0 ] && id "$OWNER" >/dev/null 2>&1; then
        chown "$OWNER:$OWNER" "$dest"
    fi

    # Parsing completo prima di toccare qualsiasi repository: un errore in lista ferma tutto.
    local rows failed=0 total=0 name url branch
    rows="$(parse_list "$file")"
    while IFS=$'\t' read -r name url branch; do
        [ -n "$name" ] || continue
        total=$((total + 1))
        sync_one "$mode" "$name" "$url" "$branch" "$dest/$name" || failed=$((failed + 1))
    done <<< "$rows"

    log ""
    log "Totale: $total · errori: $failed · cartella: $dest"
    [ "$failed" -eq 0 ] || return 1
}

run_install() {
    local auto="$1" file="$2" dest="$3"
    [ "$(id -u)" -eq 0 ] || die "install richiede root (scrive in $CRON_FILE)"
    if [ "$auto" = yes ]; then
        [ -f "$file" ] || die "file non trovato: $file"
        local cmd="$SELF update -f $(realpath "$file") -d $dest"
        mkdir -p "$(dirname "$CRON_FILE")"
        cat > "$CRON_FILE" <<EOF
# git_repos: aggiornamento settimanale dei repository (domenica 03:00). Generato da git_repos.sh
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 3 * * 0 root OWNER=$OWNER $cmd >> $LOG_FILE 2>&1
EOF
        chmod 644 "$CRON_FILE"
        touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
        ok "cron installato: $CRON_FILE (log: $LOG_FILE)"
    else
        if [ -f "$CRON_FILE" ]; then
            rm -f "$CRON_FILE"
            ok "cron rimosso: $CRON_FILE (modalità manuale)"
        else
            ok "modalità manuale: nessun cron installato"
        fi
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"
    [ -n "$cmd" ] || usage 1
    shift

    # "-auto" è un'opzione lunga per l'utente: getopts la vede come "-a"
    local norm=() x
    for x in "$@"; do
        if [ "$x" = "-auto" ]; then norm+=("-a"); else norm+=("$x"); fi
    done

    local file="" dest="$DEST_DEFAULT" auto="no" opt OPTIND=1
    while getopts ":f:d:a:h" opt "${norm[@]}"; do
        case "$opt" in
            f) file="$OPTARG" ;;
            d) dest="$OPTARG" ;;
            a) auto="$OPTARG" ;;
            h) usage 0 ;;
            :) die "manca il valore per -$OPTARG" ;;
            *) die "opzione sconosciuta: -$OPTARG" ;;
        esac
    done
    case "$auto" in yes|no) ;; *) die "-auto accetta solo yes o no" ;; esac
    [ -n "$file" ] || die "manca -f <repos.txt>"
    file="$(realpath "$file")"
    dest="$(realpath -m "$dest")"
    cd /

    # un solo processo alla volta (utile con il cron); se /run non è scrivibile uso /tmp
    local lock="$LOCK_FILE"
    [ -w "$(dirname "$lock")" ] || lock="/tmp/$(basename "$LOCK_FILE")"
    exec 9>"$lock"
    flock -n 9 || die "un'altra esecuzione è in corso"

    case "$cmd" in
        clone)   run_list clone "$file" "$dest" ;;
        update)  run_list update "$file" "$dest" ;;
        install) run_install "$auto" "$file" "$dest" ;;
        -h|--help|help) usage 0 ;;
        *) usage 1 ;;
    esac
}

main "$@"
