#!/usr/bin/env bash
# stack.sh — ambiente di test centralizzato su Debian
#   PostgreSQL 17 (container condiviso, DB: odoo, openmes)
#   Odoo 18.0    (immagine derivata con le librerie Python dei moduli)
#   OpenMES      (build dal repository GitHub Mes-Open/OpenMES)
#
#   sudo ./stack.sh install                  installa / aggiorna tutto (ripetibile)
#   sudo ./stack.sh addon sync               risolve modules.txt + dipendenze, collega, installa librerie
#   sudo ./stack.sh addon list               moduli disponibili (git e apps) e attivi
#   sudo ./stack.sh addon link <repo>/<mod>  collega un modulo git senza passare dalla lista
#   sudo ./stack.sh addon unlink <mod>       rimuove un link
#   sudo ./stack.sh status | down
#
# Credenziali di TEST:  odoo:odoo · openmes:openmes · postgres:postgres (superuser)
set -euo pipefail

# ── Configurazione (sovrascrivibile da ambiente) ─────────────────────────────
: "${STACK_DIR:=/opt/stack}"
: "${OPENMES_DIR:=/opt/openmes}"
: "${OPENMES_REPO:=https://github.com/Mes-Open/OpenMES.git}"
: "${OPENMES_HTTP_PORT:=8080}"
: "${OPENMES_HTTPS_PORT:=8443}"
: "${ODOO_VERSION:=18.0}"
: "${ODOO_PORT:=8069}"
ODOO_USER=odoo
ODOO_HOME=/home/odoo
ODOO_ADDONS="$ODOO_HOME/addons"
ODOO_REPOS_GIT="$ODOO_ADDONS/repos_git"    # repository git (OCA + altri)
ODOO_REPOS_APPS="$ODOO_ADDONS/repos_apps"  # moduli già estratti da apps.odoo.com
ODOO_ACTIVE="$ODOO_ADDONS/active"          # UNICA cartella condivisa: solo link ai moduli da caricare
ODOO_LIST="$ODOO_ADDONS/modules.txt"           # moduli richiesti (input)
ODOO_REVIEW="$ODOO_ADDONS/da_revisionare.txt"  # moduli non trovati
ODOO_MISSING="$ODOO_ADDONS/dipendenze_mancanti.txt"  # moduli con dipendenze non disponibili
TOOLS_DIR="$STACK_DIR/tools"
ODOO_BASE_IMAGE="odoo:${ODOO_VERSION}"
ODOO_IMAGE="stack-odoo:${ODOO_VERSION}"    # immagine derivata: base + librerie Python dei moduli
# Repository OCA da clonare in repos_git (il nome della cartella è l'ultima parte).
OCA_REPOS=(OCA/web OCA/server-tools)

# ── Utility ──────────────────────────────────────────────────────────────────
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "esegui con sudo"; }

wait_for() { # wait_for <descrizione> <comando...>
    local what="$1"; shift
    for _ in $(seq 1 120); do
        if "$@" >/dev/null 2>&1; then ok "$what pronto"; return 0; fi
        sleep 2
    done
    die "timeout in attesa di: $what"
}

as_odoo() { runuser -u "$ODOO_USER" -- env HOME="$ODOO_HOME" "$@"; }

pg_healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' stack-postgres 2>/dev/null)" = healthy ]; }
http_ok()    { curl -fs -o /dev/null "$1"; }

# ── 1. Docker e pacchetti ────────────────────────────────────────────────────
install_base() {
    log "Pacchetti di base e Docker"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git python3 >/dev/null
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh
    fi
    if ! docker compose version >/dev/null 2>&1; then
        apt-get install -y -qq docker-compose-plugin >/dev/null
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) · $(docker compose version --short)"
}

# ── 2. Utente odoo: home propria, nessun login (né shell né SSH) ─────────────
setup_odoo_user() {
    log "Utente di sistema '$ODOO_USER' (home propria, nessun login)"
    if ! id "$ODOO_USER" >/dev/null 2>&1; then
        useradd --create-home --home-dir "$ODOO_HOME" --shell /usr/sbin/nologin "$ODOO_USER"
    fi
    usermod --shell /usr/sbin/nologin "$ODOO_USER"
    passwd -l "$ODOO_USER" >/dev/null 2>&1 || true
    chown "$ODOO_USER:$ODOO_USER" "$ODOO_HOME"
    chmod 750 "$ODOO_HOME"
    # Migrazione dal vecchio layout (repos → repos_git).
    if [ -d "$ODOO_ADDONS/repos" ] && [ ! -e "$ODOO_REPOS_GIT" ]; then
        mv "$ODOO_ADDONS/repos" "$ODOO_REPOS_GIT"
        warn "migrato $ODOO_ADDONS/repos → repos_git"
    fi
    install -d -o "$ODOO_USER" -g "$ODOO_USER" -m 755 \
        "$ODOO_ADDONS" "$ODOO_REPOS_GIT" "$ODOO_REPOS_APPS" "$ODOO_ACTIVE"
    # Niente SSH per questo utente, anche se qualcuno gli assegnasse una chiave.
    install -d -m 755 /etc/ssh/sshd_config.d
    printf 'DenyUsers %s\n' "$ODOO_USER" > /etc/ssh/sshd_config.d/90-deny-odoo.conf
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
        warn "sshd -t ha segnalato errori: controlla la configurazione SSH"
    fi
    ok "utente $ODOO_USER pronto, home $ODOO_HOME"
}

# ── 3. Rete Docker condivisa ─────────────────────────────────────────────────
ensure_network() {
    docker network inspect stack >/dev/null 2>&1 || docker network create stack >/dev/null
    ok "rete docker 'stack'"
}

# ── 4. PostgreSQL 17 condiviso ───────────────────────────────────────────────
setup_postgres() {
    log "PostgreSQL 17 (container stack-postgres, porta 5432)"
    mkdir -p "$STACK_DIR/postgres"
    cat > "$STACK_DIR/postgres/docker-compose.yml" <<'EOF'
name: stack-postgres
services:
  postgres:
    image: postgres:17-alpine
    container_name: stack-postgres
    command:
      - postgres
      - -c
      - wal_level=logical
      - -c
      - max_replication_slots=10
      - -c
      - max_wal_senders=10
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped
    networks: [stack]
volumes:
  pgdata:
networks:
  stack:
    external: true
EOF
    docker compose -f "$STACK_DIR/postgres/docker-compose.yml" up -d
    wait_for "PostgreSQL" pg_healthy

    # Ruoli e database idempotenti. Password = nome utente (odoo:odoo, openmes:openmes).
    for role in odoo openmes; do
        docker exec -i stack-postgres psql -U postgres -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') THEN
    CREATE ROLE $role LOGIN CREATEDB PASSWORD '$role';
  ELSE
    ALTER ROLE $role LOGIN CREATEDB PASSWORD '$role';
  END IF;
END \$\$;
SQL
        if ! docker exec stack-postgres psql -U postgres -tAc \
              "SELECT 1 FROM pg_database WHERE datname='$role'" | grep -q 1; then
            docker exec stack-postgres psql -U postgres -v ON_ERROR_STOP=1 -q \
                -c "CREATE DATABASE $role OWNER $role"
        fi
        ok "database '$role' · utente '$role'"
    done
}

# ── 5. Repository OCA in repos_git ───────────────────────────────────────────
setup_oca_repos() {
    log "Repository OCA (clone in $ODOO_REPOS_GIT, branch $ODOO_VERSION)"
    for r in "${OCA_REPOS[@]}"; do
        local name="${r#*/}"
        local dst="$ODOO_REPOS_GIT/$name"
        if [ -d "$dst/.git" ]; then
            as_odoo git -C "$dst" pull --ff-only -q || warn "pull fallito per $r, lascio la versione presente"
        else
            as_odoo git clone -q --depth 1 --branch "$ODOO_VERSION" "https://github.com/$r.git" "$dst"
        fi
        ok "$r → repos_git/$name"
    done
}

# ── 6. Odoo 18 (immagine derivata con librerie dei moduli) ───────────────────
odoo_initialized() {
    docker exec stack-postgres psql -U postgres -d odoo -tAc \
        "SELECT state FROM ir_module_module WHERE name='base'" 2>/dev/null | grep -q installed
}

# Elenco dei moduli nativi dell'immagine base: serve al resolver per non cercarli nei repository.
write_core_list() {
    local out="$STACK_DIR/odoo/core_modules.txt"
    local py='import os, odoo.addons as a
for d in sorted(os.listdir(a.__path__[0])):
    if os.path.isfile(os.path.join(a.__path__[0], d, "__manifest__.py")):
        print(d)'
    docker run --rm --entrypoint python3 "$ODOO_BASE_IMAGE" -c "$py" > "$out.tmp" \
        || die "impossibile leggere i moduli nativi da $ODOO_BASE_IMAGE"
    [ -s "$out.tmp" ] || die "lista moduli nativi vuota"
    mv "$out.tmp" "$out"
    ok "moduli nativi Odoo: $(wc -l < "$out") (da $ODOO_BASE_IMAGE)"
}

setup_odoo() {
    log "Odoo $ODOO_VERSION (container stack-odoo, porta $ODOO_PORT)"
    local dir="$STACK_DIR/odoo"
    mkdir -p "$dir"
    [ -f "$dir/requirements.txt" ] || : > "$dir/requirements.txt"

    cat > "$dir/odoo.conf" <<EOF
[options]
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
db_host = stack-postgres
db_port = 5432
db_user = odoo
db_password = odoo
db_name = odoo
dbfilter = ^odoo\$
list_db = False
admin_passwd = odoo
EOF

    # Immagine derivata: installa requirements.txt (generato dal sync) nell'immagine Odoo.
    cat > "$dir/Dockerfile" <<'EOF'
FROM odoo:18.0
USER root
COPY requirements.txt /tmp/stack-requirements.txt
RUN if [ -s /tmp/stack-requirements.txt ]; then \
        python3 -m pip install --no-cache-dir --break-system-packages -r /tmp/stack-requirements.txt; \
    fi
USER odoo
EOF

    # Repository montati con il loro nome: i link relativi ../repos_git/... funzionano anche nel container.
    cat > "$dir/docker-compose.yml" <<EOF
name: stack-odoo
services:
  odoo:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${ODOO_IMAGE}
    container_name: stack-odoo
    ports:
      - "${ODOO_PORT}:8069"
    volumes:
      - odoo-data:/var/lib/odoo
      - ./odoo.conf:/etc/odoo/odoo.conf
      - ${ODOO_ACTIVE}:/mnt/extra-addons
      - ${ODOO_REPOS_GIT}:/mnt/repos_git
      - ${ODOO_REPOS_APPS}:/mnt/repos_apps
    networks: [stack]
    restart: unless-stopped
volumes:
  odoo-data:
networks:
  stack:
    external: true
EOF

    [ -s "$dir/core_modules.txt" ] || write_core_list
    local dc="docker compose -f $dir/docker-compose.yml"
    $dc build
    if ! odoo_initialized; then
        log "Creazione schema Odoo (modulo base)"
        $dc run --rm --no-deps odoo odoo -d odoo -i base --without-demo=all --stop-after-init
    fi
    # Admin Odoo: login "odoo", password "odoo" (ripetibile).
    echo "u = env.ref('base.user_admin'); u.write({'login': 'odoo', 'password': 'odoo'}); env.cr.commit()" \
        | $dc run --rm -T --no-deps odoo odoo shell -d odoo --no-http >/dev/null
    $dc up -d
    wait_for "Odoo" http_ok "http://localhost:${ODOO_PORT}/web/login"
}

# ── 7. Resolver moduli (Python) ──────────────────────────────────────────────
install_resolver() {
    install -d -m 755 "$TOOLS_DIR"
    cat > "$TOOLS_DIR/resolve_addons.py" <<'PYEOF'
#!/usr/bin/env python3
"""resolve_addons.py — risolve i moduli Odoo richiesti e le loro dipendenze ricorsive.

Usato da `stack.sh addon sync`. Non fa installazioni: crea link nella cartella
condivisa, aggiorna i file di revisione e produce requirements.txt.

Regole:
- In modules.txt ogni riga è un modulo; "modulo #git" o "#apps modulo" fissa la cartella.
- Senza hint vince git; se il modulo esiste in entrambe le cartelle viene segnalato.
- Moduli non trovati: tolti da modules.txt (backup .bak) e aggiunti a da_revisionare.txt.
- Dipendenze non trovate: il modulo resta in modules.txt e viene scritto in dipendenze_mancanti.txt.
- I link sono relativi (../repos_git/... o ../repos_apps/...), validi sia sull'host sia nel container.
"""
import argparse
import ast
import os
import pwd
import shutil
from collections import deque
from pathlib import Path

HINTS = {"#git": "git", "#apps": "apps"}


def warn(msg):
    print(f"! {msg}")


def parse_list(text):
    """Ritorna [(riga_originale, nome|None, hint|None)]. Commenti e righe vuote hanno nome None."""
    out = []
    for raw in text.splitlines():
        tokens = raw.strip().split()
        if not tokens or (tokens[0].startswith("#") and tokens[0] not in HINTS):
            out.append((raw, None, None))
            continue
        hint = next((HINTS[t] for t in tokens if t in HINTS), None)
        names = [t for t in tokens if t not in HINTS and not t.startswith("#")]
        out.append((raw, names[0] if names else None, hint))
    return out


def read_names(path):
    if not path.is_file():
        return set()
    names = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            names.add(s.split()[0])
    return names


def index_git(root):
    """Mappa nome -> cartella del modulo per root/<repo>/<modulo>/__manifest__.py."""
    idx, dups = {}, []
    if root.is_dir():
        for manifest in sorted(root.glob("*/*/__manifest__.py")):
            mod = manifest.parent
            if mod.name in idx:
                dups.append((mod.name, idx[mod.name], mod))
            else:
                idx[mod.name] = mod
    return idx, dups


def index_apps(root):
    """Mappa nome -> cartella del modulo per root/<modulo>/__manifest__.py (estratti)."""
    idx = {}
    if root.is_dir():
        for manifest in sorted(root.glob("*/__manifest__.py")):
            idx.setdefault(manifest.parent.name, manifest.parent)
    return idx


def read_manifest(mod_dir):
    """Ritorna (dict, errore). Il manifest è un dizionario letterale, letto senza eseguirlo."""
    f = mod_dir / "__manifest__.py"
    try:
        tree = ast.parse(f.read_text(encoding="utf-8"), filename=str(f))
    except (OSError, SyntaxError, UnicodeDecodeError) as exc:
        return None, str(exc)
    for node in reversed(tree.body):
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Dict):
            try:
                return ast.literal_eval(node.value), None
            except ValueError as exc:
                return None, str(exc)
    return None, "nessun dizionario nel manifest"


def read_requirements(mod_dir):
    out = []
    f = mod_dir / "requirements.txt"
    if f.is_file():
        for line in f.read_text(encoding="utf-8").splitlines():
            s = line.split("#", 1)[0].strip()
            if s and not s.startswith("-"):
                out.append(s)
    return out


def locate(name, hint, git_idx, apps_idx):
    if hint == "git":
        return ("git", git_idx[name]) if name in git_idx else None
    if hint == "apps":
        return ("apps", apps_idx[name]) if name in apps_idx else None
    if name in git_idx:
        return ("git", git_idx[name])
    if name in apps_idx:
        return ("apps", apps_idx[name])
    return None


def chown(path, uid, gid):
    os.lchown(path, uid, gid)


def write_text(path, text, uid, gid):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    chown(tmp, uid, gid)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", required=True, type=Path)
    ap.add_argument("--git-root", required=True, type=Path)
    ap.add_argument("--apps-root", required=True, type=Path)
    ap.add_argument("--active", required=True, type=Path)
    ap.add_argument("--core", required=True, type=Path)
    ap.add_argument("--review", required=True, type=Path)
    ap.add_argument("--missing", required=True, type=Path)
    ap.add_argument("--req-out", required=True, type=Path)
    ap.add_argument("--owner", default="odoo")
    a = ap.parse_args()

    pw = pwd.getpwnam(a.owner)
    uid, gid = pw.pw_uid, pw.pw_gid

    core = read_names(a.core)
    git_idx, git_dups = index_git(a.git_root)
    apps_idx = index_apps(a.apps_root)
    for name, first, second in git_dups:
        warn(f"{name}: presente in due repository git ({first} e {second}), uso il primo")

    # Diagnostica: quanti moduli/repository vede il resolver in ogni cartella.
    git_repos = {mod.parent.name for mod in git_idx.values()}
    print(f"  repos_git ({a.git_root}): {len(git_idx)} moduli in {len(git_repos)} repository")
    print(f"  repos_apps ({a.apps_root}): {len(apps_idx)} moduli")
    if not git_idx:
        warn(f"nessun modulo in {a.git_root}: attesi percorsi del tipo {a.git_root}/<repo>/<modulo>/__manifest__.py")
    if not apps_idx:
        warn(f"nessun modulo in {a.apps_root}: attesi percorsi del tipo {a.apps_root}/<modulo>/__manifest__.py")

    entries = parse_list(a.list.read_text(encoding="utf-8") if a.list.exists() else "")
    queue = deque((name, hint, None, None) for _, name, hint in entries if name)

    resolved = {}      # nome -> (cartella, path)
    not_found = {}     # nome (dalla lista principale) -> hint
    missing = set()    # (cartella, modulo che richiede, dipendenza mancante)
    py_reqs = set()
    dup_notes = set()
    core_skipped = set()

    while queue:
        name, hint, parent, parent_folder = queue.popleft()
        if name in core:
            core_skipped.add(name)
            continue
        if name in resolved:
            continue
        found = locate(name, hint, git_idx, apps_idx)
        if found is None:
            if parent is None:
                not_found.setdefault(name, hint)
            else:
                missing.add((parent_folder, parent, name))
            continue
        folder, mod_dir = found
        if hint is None and name in git_idx and name in apps_idx:
            dup_notes.add(name)
        resolved[name] = (folder, mod_dir)

        manifest, err = read_manifest(mod_dir)
        if manifest is None:
            warn(f"{name}: manifest non leggibile ({err})")
        else:
            for dep in manifest.get("depends", []) or []:
                queue.append((dep, None, name, folder))
            ext = manifest.get("external_dependencies") or {}
            py_reqs.update(ext.get("python", []) or [])
        py_reqs.update(read_requirements(mod_dir))

    # ── Link nella cartella condivisa ──────────────────────────────────────
    a.active.mkdir(parents=True, exist_ok=True)
    targets = {}
    for name, (folder, mod_dir) in resolved.items():
        root = a.git_root if folder == "git" else a.apps_root
        rel = mod_dir.relative_to(root).as_posix()
        targets[name] = f"../{root.name}/{rel}"

    report = {"creati": [], "aggiornati": [], "invariati": [], "saltati": []}
    for name in sorted(targets):
        p, t = a.active / name, targets[name]
        if p.is_symlink():
            if os.readlink(p) == t:
                report["invariati"].append(name)
                continue
            p.unlink()
            kind = "aggiornati"
        elif p.exists():
            warn(f"{p} esiste ed è una cartella/file reale: lo lascio com'è")
            report["saltati"].append(name)
            continue
        else:
            kind = "creati"
        os.symlink(t, p)
        chown(p, uid, gid)
        report[kind].append(name)
    stale = sorted(n for n in os.listdir(a.active)
                   if (a.active / n).is_symlink() and n not in targets)

    # ── Aggiornamento modules.txt e da_revisionare.txt ─────────────────────
    if not_found:
        backup = a.list.with_name(a.list.name + ".bak")
        if a.list.exists():
            shutil.copy2(a.list, backup)
            chown(backup, uid, gid)
        kept = [raw for raw, name, _ in entries if name not in not_found]
        write_text(a.list, "\n".join(kept) + "\n", uid, gid)

    review_text = a.review.read_text(encoding="utf-8") if a.review.exists() else ""
    if not review_text:
        review_text = ("# Moduli NON trovati né in repos_git né in repos_apps.\n"
                       "# Correggi (es. aggiungi #git o #apps) e rimettili in modules.txt.\n")
    existing = {n for _, n, _ in parse_list(review_text) if n}
    new_lines = []
    for name, hint in sorted(not_found.items()):
        if name in existing:
            continue
        tag = f"#{hint} " if hint else ""
        where = f"#{hint}" if hint else "git né apps"
        new_lines.append(f"{tag}{name}   # non trovato in {where}")
    if new_lines:
        review_text = review_text.rstrip("\n") + "\n" + "\n".join(new_lines) + "\n"
    write_text(a.review, review_text, uid, gid)

    # Rigenerato ad ogni sync: riflette lo stato attuale.
    missing_text = ("# Moduli caricati ma con dipendenze NON disponibili. Restano in modules.txt.\n"
                    "# Formato: cartella del modulo, modulo, dipendenza mancante.\n"
                    + "".join(f"#{folder}  {mod}  manca: {dep}\n" for folder, mod, dep in sorted(missing)))
    write_text(a.missing, missing_text, uid, gid)

    write_text(a.req_out, "".join(f"{r}\n" for r in sorted(py_reqs)), uid, gid)

    # ── Report ──────────────────────────────────────────────────────────────
    n_git = sum(1 for f, _ in resolved.values() if f == "git")
    print("== Risultato sync moduli ==")
    print(f"  collegati: {len(targets)} (git {n_git}, apps {len(targets) - n_git})")
    for kind in ("creati", "aggiornati", "invariati", "saltati"):
        if report[kind]:
            print(f"  {kind}: {', '.join(report[kind])}")
    if core_skipped:
        print(f"  core Odoo (non collegati): {', '.join(sorted(core_skipped))}")
    for name in sorted(dup_notes):
        print(f"  ! duplicato {name}: presente in git e apps, caricato quello git")
    if not_found:
        print(f"  non trovati (spostati in da_revisionare.txt): {', '.join(sorted(not_found))}")
        print(f"    (cercati in {len(git_idx)} moduli git e {len(apps_idx)} moduli apps; "
              "se il modulo è in un repository non clonato, aggiungilo a repos.txt)")
    print(f"  dipendenze mancanti: {len(missing)} (vedi dipendenze_mancanti.txt)")
    if stale:
        print(f"  link non più in lista (lasciati): {', '.join(stale)}")
    print(f"  librerie python richieste: {len(py_reqs)} -> requirements.txt")


if __name__ == "__main__":
    main()
PYEOF
    chmod 755 "$TOOLS_DIR/resolve_addons.py"
}

write_module_list_template() {
    cat > "$ODOO_LIST" <<'EOF'
# Moduli Odoo da caricare, uno per riga.
# Cartella di ricerca facoltativa: "modulo #git" oppure "#apps modulo".
# Senza hint vince git; le dipendenze vengono risolte automaticamente.
# Lascia le righe che iniziano con # come commento.
EOF
    chown "$ODOO_USER:$ODOO_USER" "$ODOO_LIST"
}

# ── 8. Sincronizzazione moduli ───────────────────────────────────────────────
sync_addons() {
    log "Sincronizzazione moduli (lista: $ODOO_LIST)"
    install_resolver
    if [ ! -f "$ODOO_LIST" ]; then
        write_module_list_template
        warn "lista creata in $ODOO_LIST: inserisci i moduli e rilancia 'addon sync'"
        return 0
    fi
    [ -s "$STACK_DIR/odoo/core_modules.txt" ] || write_core_list
    python3 "$TOOLS_DIR/resolve_addons.py" \
        --owner "$ODOO_USER" \
        --list "$ODOO_LIST" \
        --git-root "$ODOO_REPOS_GIT" \
        --apps-root "$ODOO_REPOS_APPS" \
        --active "$ODOO_ACTIVE" \
        --core "$STACK_DIR/odoo/core_modules.txt" \
        --review "$ODOO_REVIEW" \
        --missing "$ODOO_MISSING" \
        --req-out "$STACK_DIR/odoo/requirements.txt"
    chmod -R a+rX "$ODOO_REPOS_GIT" "$ODOO_REPOS_APPS" "$ODOO_ACTIVE"
    local dc="docker compose -f $STACK_DIR/odoo/docker-compose.yml"
    $dc build
    $dc up -d
    docker restart stack-odoo >/dev/null
    ok "moduli sincronizzati, Odoo riavviato"
    echo "In Odoo: Impostazioni → Modalità sviluppatore → Aggiorna elenco app."
}

# ── 9. Gestione addon ────────────────────────────────────────────────────────
addon_cmd() {
    local act="${1:-list}" arg="${2:-}"
    case "$act" in
        sync) sync_addons ;;
        list)
            echo "Moduli in repos_git:"
            find "$ODOO_REPOS_GIT" -mindepth 3 -maxdepth 3 -name '__manifest__.py' 2>/dev/null \
                | sed -e "s#^$ODOO_REPOS_GIT/##" -e 's#/__manifest__.py$##' | sort | sed 's/^/  /'
            echo "Moduli in repos_apps:"
            find "$ODOO_REPOS_APPS" -mindepth 2 -maxdepth 2 -name '__manifest__.py' 2>/dev/null \
                | sed -e "s#^$ODOO_REPOS_APPS/##" -e 's#/__manifest__.py$##' | sort | sed 's/^/  /'
            echo "Moduli attivi (in active):"
            find "$ODOO_ACTIVE" -mindepth 1 -maxdepth 1 -printf '  %f -> %l\n' | sort
            ;;
        link)
            [[ "$arg" == */* && "$arg" != *..* ]] || die "uso: addon link <repo>/<modulo>  (es. web/web_responsive)"
            [ -f "$ODOO_REPOS_GIT/$arg/__manifest__.py" ] || die "modulo non trovato in repos_git: $arg"
            local name="${arg##*/}"
            as_odoo ln -sfn "../repos_git/$arg" "$ODOO_ACTIVE/$name"
            docker restart stack-odoo >/dev/null
            ok "collegato $name (riavviato stack-odoo)"
            ;;
        unlink)
            [ -n "$arg" ] || die "uso: addon unlink <modulo>"
            [ -L "$ODOO_ACTIVE/$arg" ] || die "$arg non risulta attivo"
            rm -f "$ODOO_ACTIVE/$arg"
            docker restart stack-odoo >/dev/null
            ok "scollegato $arg (riavviato stack-odoo)"
            ;;
        *) die "addon: comando sconosciuto '$act' (sync | list | link | unlink)" ;;
    esac
}

# ── 10. OpenMES ──────────────────────────────────────────────────────────────
om() { docker compose --project-directory "$OPENMES_DIR" -f "$OPENMES_DIR/docker-compose.stack.yml" "$@"; }

setup_openmes() {
    log "OpenMES: sorgente da GitHub e configurazione"
    if [ -d "$OPENMES_DIR/.git" ]; then
        git -C "$OPENMES_DIR" pull --ff-only --quiet
    else
        git clone --depth 1 --quiet "$OPENMES_REPO" "$OPENMES_DIR"
    fi
    mkdir -p "$OPENMES_DIR/deploy/mosquitto"

    # APP_KEY: se esiste già la teniamo (cambiarla rovina sessioni e dati cifrati).
    local app_key=""
    if [ -f "$OPENMES_DIR/.env" ]; then
        app_key="$(grep -E '^APP_KEY=' "$OPENMES_DIR/.env" | cut -d= -f2- || true)"
    fi
    [ -n "$app_key" ] || app_key="base64:$(head -c32 /dev/urandom | base64 | tr -d '\n')"

    cat > "$OPENMES_DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=openmes
HTTP_PORT=${OPENMES_HTTP_PORT}
HTTPS_PORT=${OPENMES_HTTPS_PORT}
APP_KEY=${app_key}
APP_URL=http://localhost:${OPENMES_HTTP_PORT}
SANCTUM_STATEFUL_DOMAINS=localhost,localhost:${OPENMES_HTTP_PORT},localhost:${OPENMES_HTTPS_PORT}
APP_TIMEZONE=Europe/Rome
POSTGRES_DB=openmes
POSTGRES_USER=openmes
POSTGRES_PASSWORD=openmes
ADMIN_USERNAME=openmes
ADMIN_EMAIL=openmes@test.local
ADMIN_PASSWORD=openmes
EOF
    chmod 600 "$OPENMES_DIR/.env"

    cat > "$OPENMES_DIR/deploy/mosquitto/mosquitto.conf" <<'EOF'
# Broker MQTT di TEST per OpenMES. allow_anonymous solo per ambiente di test.
listener 1883
listener 9001
protocol websockets
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
EOF

    # Compose dedicato allo stack: il Postgres della repo è sostituito da stack-postgres.
    cat > "$OPENMES_DIR/docker-compose.stack.yml" <<'EOF'
name: openmes

x-env: &env
  APP_NAME: OpenMES
  APP_ENV: production
  APP_DEBUG: "false"
  APP_TIMEZONE: ${APP_TIMEZONE}
  APP_KEY: ${APP_KEY}
  APP_URL: ${APP_URL}
  SANCTUM_STATEFUL_DOMAINS: ${SANCTUM_STATEFUL_DOMAINS}
  DB_CONNECTION: pgsql
  DB_HOST: stack-postgres
  DB_PORT: "5432"
  DB_DATABASE: ${POSTGRES_DB}
  DB_USERNAME: ${POSTGRES_USER}
  DB_PASSWORD: ${POSTGRES_PASSWORD}
  QUEUE_CONNECTION: database
  SESSION_DRIVER: database
  OPENMES_TELEMETRY: "false"
  ADMIN_USERNAME: ${ADMIN_USERNAME}
  ADMIN_EMAIL: ${ADMIN_EMAIL}
  ADMIN_PASSWORD: ${ADMIN_PASSWORD}
  LOG_CHANNEL: stack
  LOG_STACK: single
  LOG_LEVEL: info
  BROADCAST_CONNECTION: reverb
  REVERB_APP_ID: openmes
  REVERB_APP_KEY: openmeskey
  REVERB_APP_SECRET: openmessecret
  REVERB_HOST: reverb
  REVERB_PORT: "8080"
  REVERB_SCHEME: http
  REVERB_SERVER_HOST: 0.0.0.0
  REVERB_SERVER_PORT: "8080"

services:
  # Unico servizio che esegue migrazioni e seeder (docker-entrypoint.sh).
  backend:
    build:
      context: .
      dockerfile: backend/Dockerfile
    image: openmes-app:local
    container_name: openmes-backend
    environment: *env
    expose: ["8000"]
    volumes:
      - backend_storage:/var/www/html/storage
      - backend_cache:/var/www/html/bootstrap/cache
    networks: [default, stack]
    restart: unless-stopped

  reverb:
    image: openmes-app:local
    pull_policy: never
    container_name: openmes-reverb
    command: ["php", "artisan", "reverb:start", "--host=0.0.0.0", "--port=8080"]
    environment: *env
    expose: ["8080"]
    networks: [default, stack]
    restart: unless-stopped

  queue-worker:
    image: openmes-app:local
    pull_policy: never
    container_name: openmes-queue-worker
    command: ["php", "artisan", "queue:work", "--sleep=1", "--tries=5", "--timeout=120"]
    environment: *env
    volumes:
      - backend_storage:/var/www/html/storage
      - backend_cache:/var/www/html/bootstrap/cache
    networks: [default, stack]
    restart: unless-stopped

  # Profilo "connectivity": OpenMES si collega al broker, non ne ospita uno.
  mqtt-listener:
    image: openmes-app:local
    pull_policy: never
    container_name: openmes-mqtt-listener
    command: ["php", "artisan", "mqtt:listen"]
    environment: *env
    volumes:
      - backend_storage:/var/www/html/storage
      - backend_cache:/var/www/html/bootstrap/cache
    networks: [default, stack]
    profiles: ["connectivity"]
    restart: unless-stopped

  mosquitto:
    image: eclipse-mosquitto:2
    container_name: openmes-mosquitto
    ports:
      - "1883:1883"
      - "9001:9001"
    volumes:
      - ./deploy/mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - mosquitto_data:/mosquitto/data
    profiles: ["connectivity"]
    restart: unless-stopped

  caddy:
    image: caddy:2-alpine
    container_name: openmes-caddy
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on: [backend]
    restart: unless-stopped

volumes:
  backend_storage:
  backend_cache:
  mosquitto_data:
  caddy_data:
  caddy_config:

networks:
  stack:
    external: true
EOF

    log "OpenMES: build (la prima volta richiede alcuni minuti)"
    om build backend
    om --profile connectivity up -d
    wait_for "OpenMES" http_ok "http://localhost:${OPENMES_HTTP_PORT}/login"
}

# ── 11. Stato, stop, riepilogo ───────────────────────────────────────────────
status() {
    docker ps --filter "name=stack-" --filter "name=openmes-" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

down() {
    om --profile connectivity down || true
    docker compose -f "$STACK_DIR/odoo/docker-compose.yml" down || true
    docker compose -f "$STACK_DIR/postgres/docker-compose.yml" down || true
    ok "stack fermato (i volumi con i dati sono conservati)"
}

summary() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ip="${ip:-localhost}"
    cat <<EOF

════════════════════════════════════════════════════════════════════
 AMBIENTE DI TEST PRONTO  (IP della VM: $ip)
════════════════════════════════════════════════════════════════════
 Odoo 18        http://$ip:${ODOO_PORT}        login: odoo / odoo   (master password: odoo)
 OpenMES        http://$ip:${OPENMES_HTTP_PORT}        login: openmes / openmes
                https://$ip:${OPENMES_HTTPS_PORT}       (certificato interno, avviso da accettare)
 PostgreSQL 17  $ip:5432   superuser postgres/postgres
                db odoo    → odoo / odoo
                db openmes → openmes / openmes
 MQTT (test)    host mosquitto:1883 (interno) · $ip:1883 · WebSocket $ip:9001
                In OpenMES: Admin → Connettività → MQTT → broker_host = mosquitto

 Moduli Odoo:   lista          $ODOO_LIST
                git           $ODOO_REPOS_GIT   (vince sempre)
                apps.odoo.com $ODOO_REPOS_APPS  (moduli già estratti)
                attivi        $ODOO_ACTIVE      (solo link)
                revisione     $ODOO_REVIEW
                dipendenze    $ODOO_MISSING
                uso:          sudo $0 addon sync

 Utente 'odoo'  home $ODOO_HOME, nessun login (shell nologin, SSH negato)
 Stato:         sudo $0 status
════════════════════════════════════════════════════════════════════
EOF
}

usage() {
    cat <<EOF
Uso: sudo $0 <comando>
  install                      installa / aggiorna tutto (ripetibile)
  addon sync                   risolve modules.txt e dipendenze, collega, installa librerie Python
  addon list                   elenca moduli git, apps e attivi
  addon link <repo>/<modulo>   collega un modulo git
  addon unlink <modulo>        rimuove un link
  status                       stato container
  down                         ferma tutto (dati conservati)
EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        install)
            require_root
            install_base
            setup_odoo_user
            ensure_network
            setup_postgres
            setup_oca_repos
            setup_odoo
            sync_addons
            setup_openmes
            summary
            ;;
        addon)  require_root; addon_cmd "$@" ;;
        status) require_root; status ;;
        down)   require_root; down ;;
        *)      usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
