# docker_odoo_openmes

Ambiente di test su una VM Debian con PostgreSQL 17, Odoo 18.0 e OpenMES, gestito da tre script bash:

| Script | Scopo |
|---|---|
| `stack.sh` | installa e configura tutto lo stack, e gestisce i moduli Odoo |
| `git_repos.sh` | clona e aggiorna repository GitHub a profondità 1 |
| `import_apps.sh` | importa i moduli Odoo scompattati nella cartella `repos_apps` |

Gli script sono pensati per un ambiente di **test**. Le credenziali sono volutamente semplici e non vanno usate in produzione.

## Architettura

- **PostgreSQL 17** in un container condiviso (`stack-postgres`), con i database `odoo` e `openmes`. Kosha verrà aggiunto come terzo database.
- **Odoo 18.0** in un'immagine derivata (`stack-odoo:18.0`), che installa le librerie Python richieste dai moduli.
- **OpenMES** compilato dal repository indicato in `OPENMES_REPO`, con i profili `connectivity` (MQTT).
- Una cartella `addons` nella home dell'utente di sistema `odoo`, con sottocartelle `repos_git`, `repos_apps` e `active`. Odoo legge solo `active`, che contiene link simbolici ai moduli da caricare.

Credenziali di test: `odoo:odoo` (login admin Odoo, master password `odoo`), `openmes:openmes` (admin OpenMES), `postgres:postgres` (superuser).

L'utente di sistema `odoo` non può accedere via SSH (`DenyUsers odoo`) e non ha shell di login.

---

## stack.sh

**Scopo.** Installa e aggiorna l'intero stack in modo ripetibile: Docker, utente `odoo`, rete Docker, PostgreSQL, repository OCA, Odoo, OpenMES e la sincronizzazione dei moduli. Include un risolutore delle dipendenze: legge una lista di moduli, cerca ogni modulo nei repository git e nelle app scompattate, segue ricorsivamente le dipendenze e crea i link in `active`.

**Uso**

```
sudo ./stack.sh install                  installa / aggiorna tutto (ripetibile)
sudo ./stack.sh addon sync               risolve modules.txt e le dipendenze, collega, installa le librerie Python
sudo ./stack.sh addon list               elenca i moduli git, apps e attivi
sudo ./stack.sh addon link <repo>/<mod>  collega un modulo git senza passare dalla lista
sudo ./stack.sh addon unlink <mod>       rimuove un link
sudo ./stack.sh status                   stato dei container
sudo ./stack.sh down                     ferma tutto, dati conservati
```

**Variabili d'ambiente** (tutte facoltative)

| Variabile | Default | Significato |
|---|---|---|
| `STACK_DIR` | `/opt/stack` | cartella di lavoro dello stack |
| `OPENMES_DIR` | `/opt/openmes` | clone del repository OpenMES |
| `OPENMES_REPO` | `https://github.com/Mes-Open/OpenMES.git` | repository da cui compilare OpenMES (per usare un fork) |
| `OPENMES_HTTP_PORT` | `8080` | porta HTTP di OpenMES |
| `OPENMES_HTTPS_PORT` | `8443` | porta HTTPS di OpenMES |
| `ODOO_VERSION` | `18.0` | versione dell'immagine Odoo |
| `ODOO_PORT` | `8069` | porta di Odoo |

I repository OCA clonati all'installazione sono nell'array `OCA_REPOS` in cima allo script (default: `OCA/web`, `OCA/server-tools`).

**File gestiti in `/home/odoo/addons`**

- `modules.txt`: l'elenco dei moduli richiesti, uno per riga. Una riga può contenere un hint `#git` o `#apps` per indicare dove cercare il modulo.
- `da_revisionare.txt`: moduli non trovati nei repository. Lo script li sposta qui dalla lista principale.
- `dipendenze_mancanti.txt`: dipendenze non disponibili, con la cartella in cui si trova il modulo che le richiede.
- `requirements.txt`: librerie Python richieste dai moduli collegati, installate nell'immagine Odoo.
- `modules.txt.bak`: copia della lista precedente, creata solo quando lo script sposta dei moduli.

Quando un modulo viene collegato a `active`, il link è relativo (`../repos_git/<repo>/<mod>` o `../repos_apps/<mod>`), quindi funziona sia sulla VM sia dentro il container.

**Note**

- Se un file di lista arriva da Windows, lo script ignora il ritorno a capo finale.
- In caso di errore durante `install` lo script si ferma; si può rilanciare, perché salta i passaggi già completati.

---

## git_repos.sh

**Scopo.** Legge un file con l'elenco dei repository GitHub e li clona in una cartella, con `--depth 1 --single-branch` sul branch indicato. Se un repository è già presente, lo aggiorna. Se cambiano il branch o l'origine, lo ricrea da zero. Con `-auto yes` installa un cron settimanale per aggiornarli.

**Uso**

```
git_repos.sh clone   -f repos.txt [-d DIR]                 clona i repository mancanti
git_repos.sh update  -f repos.txt [-d DIR]                 aggiorna quelli già presenti
git_repos.sh install -f repos.txt [-d DIR] [-auto yes|no]  come clone, con cron opzionale
```

- `-d DIR`: cartella di destinazione. Default `/home/odoo/addons/repos_git`.
- `-auto yes`: crea `/etc/cron.d/git-repos-update`, che ogni domenica alle 03:00 esegue `update`. Il log è `/var/log/git_repos.log`. Con `-auto no` o senza l'opzione non viene creato nessun cron.

**Formato di repos.txt**, una riga per repository:

```
OCA/web 18.0
https://github.com/OCA/server-tools.git 18.0
# le righe con # sono ignorate
```

Ogni riga ha il repository (come `owner/repo` oppure URL) e il branch, separati da uno spazio. Un repository per riga.

**Variabili utili:** `OWNER` (utente che possiede i repository, default `odoo`), `CRON_FILE`, `LOG_FILE`, `LOCK_FILE`.

**Note**

- Lo script gira come root, ma esegue i comandi `git` come `OWNER`, per evitare problemi di proprietà.
- Un'esecuzione alla volta: un file di lock impedisce esecuzioni concorrenti.
- Se un clone fallisce, lo script lo segnala e prosegue con gli altri.

---

## import_apps.sh

**Scopo.** Importa i moduli Odoo già scompattati da una cartella sorgente (per esempio i moduli scaricati da apps.odoo.com) nella cartella `repos_apps`. Per ogni modulo copia la cartella, verifica che la copia sia identica all'originale con `diff -r`, assegna la proprietà all'utente `odoo` e solo a quel punto cancella l'originale.

**Uso**

```
sudo ./import_apps.sh                  usa i valori di default
sudo ./import_apps.sh -n               simulazione: mostra cosa farebbe, senza toccare nulla
sudo ./import_apps.sh -s SRC -d DST    cartelle personalizzate
```

- `-s SRC`: cartella sorgente. Default `/home/ammstanc/addon`.
- `-d DST`: cartella di destinazione. Default `/home/odoo/addons/repos_apps`.
- `-n`: simulazione.

**Regole**

- Viene copiata solo una cartella che contiene `__manifest__.py`, cioè un modulo Odoo.
- Se la destinazione contiene già una cartella con lo stesso nome, non viene sovrascritta: il modulo resta nella sorgente e lo script lo segnala.
- Link simbolici, file (come zip o README) e cartelle senza manifest non vengono toccati.
- Se la copia non è identica all'originale, la copia viene eliminata e l'originale resta dove si trova.
- Lo script esce con codice diverso da zero se un modulo non è stato copiato o verificato correttamente. I moduli saltati per le regole sopra non sono errori.

Dopo l'importazione, per collegare i moduli a Odoo usa `sudo ./stack.sh addon sync`.

---

## File di input

**`repos.txt`** elenca i repository GitHub da clonare con `git_repos.sh`. Esempio incluso in questo repository.

**`modules.txt`** elenca i moduli Odoo da collegare ad Active con `stack.sh addon sync`. Esempio incluso in questo repository.

Entrambi i file accettano commenti con `#` all'inizio della riga. Per i moduli, gli hint `#git` e `#apps` indicano dove cercare il modulo.
