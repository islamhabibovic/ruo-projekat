# Troslojna aplikacija kao kod

Projektni zadatak iz predmeta **Računarstvo u oblaku** (Politehnički fakultet Zenica, II ciklus, 2026/27).
Kompletna infrastruktura za web aplikaciju (frontend, backend, baza) opisana isključivo kodom:
virtuelne mašine (Terraform + libvirt), početna konfiguracija (cloud-init), konfiguracija servera (Ansible role),
kontejneri (Docker Compose), segmentirana mreža (Docker mreže s fiksnim podmrežama) i DNS (BIND + Terraform `hashicorp/dns`).

Dizajnerske odluke (DO-1 do DO-9) i ADR-ovi su u PDF dokumentu koji se predaje uz ovaj repozitorij
(izvor: [`docs/odluke.md`](docs/odluke.md)).

## Sadržaj

1. [Aplikacija](#1-aplikacija)
2. [Arhitektura i stvarni raspored](#2-arhitektura-i-stvarni-raspored)
3. [Plan adresiranja i izolacija slojeva](#3-plan-adresiranja-i-izolacija-slojeva)
4. [DNS](#4-dns)
5. [Tajne](#5-tajne)
6. [Pokretanje od praznog računara](#6-pokretanje-od-praznog-računara)
7. [Struktura repozitorija](#7-struktura-repozitorija)
8. [Dokazi: idempotentnost, testovi, drift](#8-dokazi-idempotentnost-testovi-drift)
9. [Izmjene tokom odbrane](#9-izmjene-tokom-odbrane)
10. [Mapiranje na obavezne odluke (AO)](#10-mapiranje-na-obavezne-odluke-ao)

## 1. Aplikacija

**Bilješke**: jednostavna vlastita web aplikacija za unos, pregled i brisanje kratkih bilješki.
Aplikacija nije predmet ocjenjivanja, pa je namjerno mala, ali koristi sva tri sloja.

| Sloj | Kontejner | Tehnologija | Uloga |
|---|---|---|---|
| frontend | `frontend` | nginx 1.27 (alpine) | statična stranica + reverse proxy `/api/` → backend |
| backend | `backend` | Python 3.12, Flask, gunicorn, psycopg 3 | REST API (`/api/biljeske`, `/api/health/db`) |
| baza | `db` | PostgreSQL 16 (alpine) + Docker volume `projekat-pgdata` | trajni podaci |

Tok zahtjeva je isključivo **frontend → backend → baza** (AO-1). Frontend backend traži po imenu
`backend.projekat.ruo.lab`, a backend bazu po imenu `db.projekat.ruo.lab` (AO-7).

## 2. Arhitektura i stvarni raspored

Izabrana je varijanta **A** iz DO-2: jedna VM za aplikaciju, na kojoj su segmenti Docker mreže s fiksnim
podmrežama, i zasebna VM za DNS.

```text
                         Administrator (host: WSL2/Linux, 10.60.0.1)
                         make · terraform · ansible-playbook · dig · nsupdate
                                         │ SSH (ključ), RFC 2136 + TSIG
          ┌──────────────────────────────┴──────────────────────────────┐
          │  libvirt mreža "projekat"  10.60.0.0/24  (NAT prema internetu)│
          │                                                              │
          │  ┌───────────────────────┐      ┌──────────────────────────────────────────────────┐
          │  │ ns1   10.60.0.53      │      │ app1   10.60.0.10   (Docker)                     │
          │  │ BIND 9, autoritativni │◄─────┤                                                  │
          │  │ zona projekat.ruo.lab │ DNS  │  :80 ─► ┌──────────┐                             │
          │  │ (Terraform mijenja    │upiti │         │ frontend │ seg-web 10.61.1.0/24        │
          │  │  zapise, TSIG)        │      │         │ .1.10    │                             │
          │  └───────────────────────┘      │         │ .2.20    ├──┐ seg-app 10.61.2.0/24     │
          │                                 │         └──────────┘  ▼                          │
          │                                 │               ┌──────────┐                       │
          │                                 │               │ backend  │ .2.10                 │
          │                                 │               │          │ .3.20                 │
          │                                 │               └────┬─────┘                       │
          │                                 │                    ▼  seg-db 10.61.3.0/24        │
          │                                 │               ┌──────────┐  (internal: bez       │
          │                                 │               │ db       │ .3.10   puta van)     │
          │                                 │               │ + volume │  nema objavljen port  │
          │                                 │               └──────────┘                       │
          │                                 └──────────────────────────────────────────────────┘
          └──────────────────────────────────────────────────────────────┘
   Korisnik ──► http://www.projekat.ruo.lab  (CNAME app1 → 10.60.0.10:80)  = jedini ulaz izvana
```

| VM | Adresa | Resursi (Terraform varijable) | Uloga |
|---|---|---|---|
| `projekat-ns1` | 10.60.0.53 | 512 MB, 1 vCPU, 8 GB | BIND 9: zona `projekat.ruo.lab` + reverzna `0.60.10.in-addr.arpa` |
| `projekat-app1` | 10.60.0.10 | 2048 MB, 2 vCPU, 15 GB | Docker Engine + Compose v2: frontend, backend, db |

## 3. Plan adresiranja i izolacija slojeva

Sve adrese su na jednom mjestu: [`plan-adresa.yaml`](plan-adresa.yaml). Čitaju ga Terraform (`yamldecode`)
i Ansible (`vars_files`), pa se adresa nikad ne ponavlja ručno na drugom mjestu.

| Segment | Podmreža | Gateway | Kontejneri (adresa) | Napomena |
|---|---|---|---|---|
| libvirt `projekat` | 10.60.0.0/24 | 10.60.0.1 (host) | ns1 .53, app1 .10 | NAT, statičke DHCP rezervacije |
| `seg-web` (br-web) | 10.61.1.0/24 | 10.61.1.1 | frontend .10 | jedini segment s objavljenim portom (80) |
| `seg-app` (br-app) | 10.61.2.0/24 | 10.61.2.1 | backend .10, frontend .20 | izlaz prema ns1 za DNS upite |
| `seg-db` (br-db) | 10.61.3.0/24 | — | db .10, backend .20 | `internal: true`, nema izlaza ni rute |

**Kako su slojevi izolovani (AO-6):**

- Kontejner je samo na mrežama koje mu trebaju: frontend na `seg-web` i `seg-app`, backend na `seg-app` i
  `seg-db`, baza samo na `seg-db`. **Frontend nema sučelje u segmentu baze.**
- Docker između različitih bridge mreža ne prosljeđuje promet (pravila `DOCKER-ISOLATION` u iptables), pa ni
  pokušaj po IP adresi (frontend → 10.61.3.10) ne prolazi.
- `seg-db` je `internal`: nema gatewaya ni NAT-a, baza ne može van segmenta.
- Port je objavljen samo za frontend (`80:80`). Backend i baza nemaju `ports`, pa nisu dostupni ni s hosta.
- Sve se provjerava testom [`tests/izolacija.sh`](tests/izolacija.sh) (dozvoljeni tokovi moraju uspjeti,
  zabranjeni moraju pasti).

## 4. DNS

- Autoritativni BIND na `ns1` (`recursion no`, AXFR zabranjen, upiti dozvoljeni samo iz 10.60.0.0/24).
- Zona **`projekat.ruo.lab`** je dinamička. Ansible postavlja samo početni sadržaj (SOA, NS, `ns1`) i to samo
  pri prvom kreiranju (`force: false`); zapise servisa dodaje i održava **Terraform** (`terraform/dns`,
  provider `hashicorp/dns`, RFC 2136).
- TSIG ključ `tf-projekat` (HMAC-SHA256) ima `update-policy { grant tf-projekat zonesub ANY; }` samo u zoni
  projekta. Reverzna zona nema update-policy, pa je ključ ne može mijenjati (test u `tests/dns.sh`).
- Zapisi (TTL 60 s):

| Ime | Tip | Vrijednost | Ko upravlja |
|---|---|---|---|
| `ns1` | A | 10.60.0.53 | Ansible (glue za NS) |
| `app1` | A | 10.60.0.10 | Terraform |
| `www` | CNAME | `app1.projekat.ruo.lab.` | Terraform |
| `frontend` | A | 10.61.1.10 | Terraform |
| `backend` | A | 10.61.2.10 | Terraform |
| `db` | A | 10.61.3.10 | Terraform |
| `@` | TXT | vlasnik zapisa | Terraform |
| `10`, `53` u `0.60.10.in-addr.arpa` | PTR | `app1`, `ns1` | Ansible |

- Kontejneri frontend i backend imaju `dns: [ns1]` u `compose.yaml`: Dockerov ugrađeni DNS imena iz zone
  projekta prosljeđuje BIND-u. U kodu aplikacije nema IP adresa (provjerava `tests/kod.sh`).

## 5. Tajne

| Tajna | Gdje nastaje | Gdje se čuva | U Gitu |
|---|---|---|---|
| Lozinka baze | `make vault` (`openssl rand`) | `ansible/group_vars/app/vault.yml`, šifrovano ansible-vault-om; na app1 `/opt/projekat/secrets/db_password` (direktorij 0700), u kontejnere kao Docker secret | ne (samo `vault.yml.example`) |
| Vault lozinka | `make vault` | `.vault_pass` (0600) | ne |
| TSIG ključ | Ansible na ns1 (`tsig-keygen`, samo ako ne postoji) | `/etc/bind/tf-projekat.key` (root:bind 0640); lokalno `.secrets/` (0600) za Terraform | ne |
| SSH ključ | `make ssh-key` | `~/.ssh/id_ed25519` | ne |
| Terraform state | `terraform apply` | `terraform/*/terraform.tfstate` | ne |

Sve je u [`.gitignore`](.gitignore), a `tests/kod.sh` pretražuje cijelu historiju repozitorija.

## 6. Pokretanje od praznog računara

### 6.1 Preduslovi (jednom)

Računar s Ubuntu 22.04/24.04 (ili Windows + WSL2 Ubuntu) i podrškom za KVM (`/dev/kvm`). Najlakše je pokrenuti
instalacijsku skriptu iz repozitorija predmeta, koja instalira Terraform, Ansible, KVM/libvirt, pravi libvirt
pool `default` i SSH ključ:

```bash
cd ~ && git clone https://github.com/Dadyze/RuO-2026-27.git && cd RuO-2026-27 && ./00-setup.sh
# u WSL2 nakon upozorenja o systemd/grupama: u PowerShellu "wsl --shutdown", pa ponovo ./00-setup.sh
sudo apt install -y bind9-dnsutils openssl curl     # dig i nsupdate za testove i demonstraciju drifta
```

Repozitorij projekta mora biti u Linux fajl sistemu (`~/...`), ne na `/mnt/c/...` (Ansible tada ignoriše
`ansible.cfg`).

```bash
cd ~ && git clone <URL ovog repozitorija> projekat && cd projekat
make check          # svi alati moraju biti "ok"
```

### 6.2 Podizanje, test, uklanjanje

```bash
make all            # = infra → config → dns → deploy  (prvi put ~10 min, većinom preuzimanje slika)
make test           # DNS, izolacija, aplikacija, kod: na kraju "SVI TESTOVI SU PROŠLI"
make all            # drugo izvršavanje: Terraform "No changes", Ansible changed=0
make destroy        # uklanja sve što je projekat kreirao
```

Isti koraci bez Makefilea (tačan redoslijed):

| Korak | Naredba |
|---|---|
| 0. ključ, Vault, slika | `ssh-keygen -t ed25519` (ako ne postoji) · `make vault` · `make slika` |
| 1. infra | `terraform -chdir=terraform/vm init && terraform -chdir=terraform/vm apply` (pravi i `ansible/inventory.ini`) |
| 2. config | `ansible-galaxy collection install -r ansible/requirements.yml && cd ansible && ansible-playbook site.yml` |
| 3. dns | `TF_VAR_tsig_secret=$(cat .secrets/tsig-tf-projekat.secret) terraform -chdir=terraform/dns apply` |
| 4. deploy | `cd ansible && ansible-playbook deploy.yml` |
| test | `bash tests/dns.sh; bash tests/izolacija.sh; bash tests/app.sh; bash tests/kod.sh` |
| destroy | `terraform -chdir=terraform/dns destroy` (ili brisanje state-a ako ns1 više ne postoji) · `terraform -chdir=terraform/vm destroy` |

Ostali ciljevi: `make plan` (oba plana, očekuje se bez promjena), `make idempotencija`, `make drift`,
`make dokazi` (upisuje stvarne izlaze u ovaj README).

Aplikacija u browseru hosta: `http://10.60.0.10/` (ili `http://www.projekat.ruo.lab/` ako host za tu zonu
koristi ns1 kao resolver).

## 7. Struktura repozitorija

```text
projekat/
├── plan-adresa.yaml          # jedini izvor istine za adrese i imena (DO-3, DO-8)
├── app/
│   ├── frontend/             # nginx: Dockerfile, predložak konfiguracije, statična stranica
│   ├── backend/              # Flask API: Dockerfile (multi-stage), app.py, requirements.txt
│   ├── compose.yaml          # 3 servisa, 3 segmenta, volume, secret (bez ijedne IP adrese)
│   └── .env.example          # .env generiše Ansible iz plan-adresa.yaml
├── terraform/
│   ├── vm/                   # libvirt mreža, bazna slika, diskovi, cloud-init, VM-ovi, inventory (AO-3)
│   └── dns/                  # DNS zapisi servisa (AO-8)
├── cloud-init/user-data.tftpl # korisnik, SSH ključ, bez lozinke (AO-4)
├── ansible/
│   ├── site.yml              # common (svi), bind (dns), docker (app)
│   ├── deploy.yml            # app (isporuka aplikacije)
│   ├── roles/{common,bind,docker,app}
│   └── group_vars/app/       # vars.yml + vault.yml (šifrovan, nije u Gitu) + vault.yml.example
├── tests/                    # dns.sh, izolacija.sh, app.sh, kod.sh, drift.sh, dokazi.sh
├── docs/                     # odluke.md (izvor PDF-a s ADR-ovima), izlazi/ (izlazi provjera)
└── Makefile
```

Odstupanje od preporučene strukture: dodata je datoteka `plan-adresa.yaml` u korijenu (zajednička Terraformu
i Ansibleu), a `compose.yaml` koristi varijable iz `.env` koji pravi Ansible, kako bi adrese bile samo na jednom
mjestu.

## 8. Dokazi: idempotentnost, testovi, drift

Izlazi ispod se upisuju automatski naredbom `make dokazi` (nakon `make all`) i čuvaju se i u `docs/izlazi/`.

### 8.1 Drugo izvršavanje Ansible playbooka i Terraform plan (idempotentnost)

<!-- IZLAZ:idempotencija -->
```text

PLAY [Osnovna konfiguracija svih VM-ova] ***************************************

TASK [Čekaj da SSH postane dostupan] *******************************************
ok: [app1]
ok: [ns1]

TASK [Čekaj da cloud-init završi] **********************************************
ok: [ns1]
ok: [app1]

TASK [Prikupi činjenice] *******************************************************
ok: [ns1]
ok: [app1]

TASK [common : Osnovni paketi] *************************************************
ok: [app1]
ok: [ns1]

TASK [common : Vremenska zona] *************************************************
ok: [app1]
ok: [ns1]

TASK [common : Prijava lozinkom je onemogućena (provjera onoga što je postavio cloud-init, AO-4)] ***
ok: [app1]
ok: [ns1]

PLAY [Autoritativni DNS server zone projekta (AO-7)] ***************************

TASK [Gathering Facts] *********************************************************
ok: [ns1]

TASK [bind : BIND 9] ***********************************************************
ok: [ns1]

TASK [bind : TSIG ključ za Terraform (generiše se samo ako ne postoji)] ********
ok: [ns1]

TASK [bind : Prava nad TSIG ključem (čita ga samo named)] **********************
ok: [ns1]

TASK [bind : Direktorij za statičke zone] **************************************
ok: [ns1]

TASK [bind : Opcije servera (samo autoritativni, bez rekurzije)] ***************
ok: [ns1]

TASK [bind : Zone projekta] ****************************************************
ok: [ns1]

TASK [bind : Reverzna zona (statička, upravlja Ansible)] ***********************
ok: [ns1]

TASK [bind : Početni sadržaj dinamičke zone (SOA, NS, ns1)] ********************
ok: [ns1]

TASK [bind : Provjera cijele konfiguracije (named-checkconf -z)] ***************
ok: [ns1]

TASK [bind : named radi i pokreće se pri boot-u] *******************************
ok: [ns1]

TASK [bind : Primijeni izmjene konfiguracije prije nastavka] *******************

TASK [bind : Pročitaj TSIG ključ] **********************************************
ok: [ns1]

TASK [bind : Lokalni direktorij za tajne (izvan Gita)] *************************
ok: [ns1 -> localhost]

TASK [bind : TSIG tajna za terraform/dns (lokalno, 0600)] **********************
ok: [ns1 -> localhost]

PLAY [Docker host za kontejnere aplikacije] ************************************

TASK [Gathering Facts] *********************************************************
ok: [app1]

TASK [docker : Docker Engine i Compose plugin] *********************************
ok: [app1]

TASK [docker : Konfiguracija Docker daemona] ***********************************
ok: [app1]

TASK [docker : Docker radi i pokreće se pri boot-u] ****************************
ok: [app1]

TASK [docker : Administrator smije koristiti docker bez sudo (dijagnostika)] ***
ok: [app1]

PLAY RECAP *********************************************************************
app1                       : ok=11   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
ns1                        : ok=20   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   


PLAY [Isporuka troslojne aplikacije] *******************************************

TASK [Gathering Facts] *********************************************************
ok: [app1]

TASK [app : Direktorij aplikacije] *********************************************
ok: [app1]

TASK [app : Kod aplikacije (frontend, backend, compose.yaml)] ******************
ok: [app1]

TASK [app : Direktorij za tajne (samo root)] ***********************************
ok: [app1]

TASK [app : Lozinka baze iz ansible-vault-a (AO-9)] ****************************
ok: [app1]

TASK [app : Okruženje za compose (.env iz plana adresiranja)] ******************
ok: [app1]

TASK [app : Aplikacija radi (docker compose up)] *******************************
ok: [app1]

TASK [app : Frontend odgovara na VM-u] *****************************************
ok: [app1]

PLAY RECAP *********************************************************************
app1                       : ok=19   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
ns1                        : ok=20   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   

Ansible: changed=0 na svim hostovima
terraform -chdir=terraform/vm plan -input=false -detailed-exitcode
TF_VAR_tsig_secret="$(cat .secrets/tsig-tf-projekat.secret)" terraform -chdir=terraform/dns plan -input=false -detailed-exitcode
libvirt_cloudinit_disk.init["ns1"]: Refreshing state... [id=/var/lib/libvirt/images/projekat-ns1-init.iso;9e66a9f0-86e0-46c2-a0c0-72999691245e]
libvirt_volume.base: Refreshing state... [id=/var/lib/libvirt/images/projekat-ubuntu-noble-base.qcow2]
libvirt_network.projekat: Refreshing state... [id=8adc92de-6d09-415d-b6c5-3027a125341b]
libvirt_cloudinit_disk.init["app1"]: Refreshing state... [id=/var/lib/libvirt/images/projekat-app1-init.iso;367b711d-479d-4b60-a00e-18b40b00b80c]
libvirt_volume.disk["app1"]: Refreshing state... [id=/var/lib/libvirt/images/projekat-app1.qcow2]
libvirt_volume.disk["ns1"]: Refreshing state... [id=/var/lib/libvirt/images/projekat-ns1.qcow2]
libvirt_domain.vm["ns1"]: Refreshing state... [id=eedcb1a8-c00b-47e2-be77-60920a044105]
libvirt_domain.vm["app1"]: Refreshing state... [id=af58bbc3-c1d1-45c9-a4c9-566083fed53a]
local_file.inventory: Refreshing state... [id=2e16b6b8795fd3a4143de5c8fbc0a72c23fdc9f4]

No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
dns_cname_record.www: Refreshing state... [id=www.projekat.ruo.lab.]
dns_txt_record_set.vlasnik: Refreshing state... [id=projekat.ruo.lab.]
dns_a_record_set.servis["backend"]: Refreshing state... [id=backend.projekat.ruo.lab.]
dns_a_record_set.vm["app1"]: Refreshing state... [id=app1.projekat.ruo.lab.]
dns_a_record_set.servis["frontend"]: Refreshing state... [id=frontend.projekat.ruo.lab.]
dns_a_record_set.servis["db"]: Refreshing state... [id=db.projekat.ruo.lab.]

No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
```
<!-- /IZLAZ:idempotencija -->

### 8.2 Testovi (DNS, izolacija, aplikacija, kod)

<!-- IZLAZ:testovi -->
```text

== DNS: zona projekat.ruo.lab na serveru 10.60.0.53
$ dig @10.60.0.53 projekat.ruo.lab SOA
ns1.projekat.ruo.lab. hostmaster.projekat.ruo.lab. 9 3600 600 1209600 60
  PROŠLO  autoritativni odgovor (flag aa)
  PROŠLO  NS zapis zone  [ns1.projekat.ruo.lab.]

== Zapisi servisa (terraform/dns)
  frontend.projekat.ruo.lab  A  10.61.1.10
  PROŠLO  frontend.projekat.ruo.lab postoji
  backend.projekat.ruo.lab   A  10.61.2.10
  PROŠLO  backend.projekat.ruo.lab postoji
  db.projekat.ruo.lab        A  10.61.3.10
  PROŠLO  db.projekat.ruo.lab postoji
  app1.projekat.ruo.lab      A  10.60.0.10
  PROŠLO  app1.projekat.ruo.lab postoji
  ns1.projekat.ruo.lab       A  10.60.0.53
  PROŠLO  ns1.projekat.ruo.lab postoji
  PROŠLO  www je CNAME na app1  [app1.projekat.ruo.lab.]
  PROŠLO  www i app1 daju istu adresu  [10.60.0.10]
  PROŠLO  PTR za app1  [app1.projekat.ruo.lab.]

== Server je samo autoritativni
  PROŠLO  tuđa domena (example.com): REFUSED  [status: REFUSED]
  PROŠLO  nepostojeće ime: NXDOMAIN  [status: NXDOMAIN]
  PROŠLO  prijenos zone (AXFR) je odbijen

== TSIG ključ tf-projekat smije mijenjati SAMO zonu projekta (AO-8)
  PROŠLO  UPDATE u zoni projekat.ruo.lab dozvoljen
  $ nsupdate (zona 0.60.10.in-addr.arpa) -> update failed: REFUSED
  PROŠLO  UPDATE u reverznoj zoni odbijen (REFUSED)
  PROŠLO  UPDATE bez TSIG ključa odbijen (REFUSED)

Rezultat: 16 prošlo, 0 palo

== Segmenti na app1 (Docker mreže)
seg-web  10.61.1.0/24  internal=false  kontejneri: frontend 
seg-app  10.61.2.0/24  internal=false  kontejneri: backend frontend 
seg-db  10.61.3.0/24  internal=true  kontejneri: db backend 
  PROŠLO  seg-db je internal (bez puta van segmenta)  [true]

== Dozvoljeni tokovi: frontend -> backend -> baza (po DNS imenima)
  PROŠLO  frontend -> backend.projekat.ruo.lab:8000
  PROŠLO  backend  -> db.projekat.ruo.lab:5432

== Zabranjeni tokovi (moraju pasti)
  PROŠLO  frontend -> db.projekat.ruo.lab:5432 (frontend nema put do baze)
  PROŠLO  frontend -> 10.61.3.10:5432 (ni direktno po adresi)
  PROŠLO  baza -> internet (seg-db je internal)

== Objavljeni portovi: izvana je dostupan samo frontend
db	5432/tcp
frontend	0.0.0.0:80->80/tcp, [::]:80->80/tcp
backend	8000/tcp
  PROŠLO  baza nema objavljen port  []
  PROŠLO  backend nema objavljen port  []
  PROŠLO  host -> app1:80   (frontend)
  PROŠLO  host -> app1:8000 (backend)
  PROŠLO  host -> app1:5432 (baza)

Rezultat: 11 prošlo, 0 palo
www.projekat.ruo.lab -> 10.60.0.10 (razriješeno na ns1)

== Aplikacija kroz frontend (jedini ulaz)
  PROŠLO  GET / (frontend)  [200]
  {"baza":"db.projekat.ruo.lab","status":"ok"}
  PROŠLO  frontend -> backend -> baza (/api/health/db)

== AO-10: podaci preživljavaju ponovno kreiranje kontejnera baze
  POST: {"id":2,"kreirano":"2026-11-21T18:28:22.176853+00:00","tekst":"test-postojanosti-1795285701"}
  PROŠLO  bilješka upisana
  $ docker compose rm -sf db && docker compose up -d --wait db
  kontejner baze: 5b64e411882a -> 64abe6abe21a
  PROŠLO  kontejner baze je novi
  PROŠLO  bilješka postoji nakon ponovnog kreiranja

Rezultat: 5 prošlo, 0 palo

== IP adrese u kodu aplikacije (app/)
  PROŠLO  app/ ne sadrži nijednu adresu komponente (samo DNS imena)

== Datoteke koje ne smiju biti u Gitu (AO-9)
  (nije Git repozitorij, preskačem)

Rezultat: 1 prošlo, 0 palo

SVI TESTOVI SU PROŠLI
```
<!-- /IZLAZ:testovi -->

### 8.3 Drift DNS zapisa

Opis: zapisima servisa upravlja Terraform. Skripta [`tests/drift.sh`](tests/drift.sh) ih mijenja "ručno",
mimo koda, naredbom `nsupdate` (s istim TSIG ključem): `db` dobija pogrešnu adresu 10.61.3.99, a `backend`
se briše. Posljedica u stvarnom sistemu: backend više ne može doći do baze, a frontend do backenda.
`terraform plan` upoređuje stanje iz koda sa stvarnim stanjem na serveru (refresh) i prijavljuje
`dns_a_record_set.servis["db"]` za izmjenu (`~ addresses`) i `dns_a_record_set.servis["backend"]` za ponovno
kreiranje. `terraform apply` vraća zapise na vrijednosti iz koda, a sljedeći plan je `No changes`.
Isti obrazac važi za drift na VM-u (npr. `virsh setmem` mimo koda): izmjena se vidi u planu i ispravlja applyjem.

<!-- IZLAZ:drift -->
```text

== 1. Ručna izmjena mimo koda: db dobija pogrešnu adresu, backend se briše
$ nsupdate: update delete db.projekat.ruo.lab A; update add db.projekat.ruo.lab 60 A 10.61.3.99; update delete backend.projekat.ruo.lab A
db: 10.61.3.99   backend: ''

== 2. terraform plan otkriva drift
  + create
  ~ update in-place
  # dns_a_record_set.servis["backend"] will be created
  + resource "dns_a_record_set" "servis" {
      + addresses = [
          + "10.61.2.10",
      + id        = (known after apply)
      + name      = "backend"
      + ttl       = 60
      + zone      = "projekat.ruo.lab."
  # dns_a_record_set.servis["db"] will be updated in-place
  ~ resource "dns_a_record_set" "servis" {
      ~ addresses = [
          - "10.61.3.99",
          + "10.61.3.10",
        # (2 unchanged attributes hidden)
Plan: 1 to add, 1 to change, 0 to destroy.

== 3. terraform apply vraća stanje iz koda
dns_a_record_set.servis["backend"]: Creating...
dns_a_record_set.servis["db"]: Modifying... [id=db.projekat.ruo.lab.]
dns_a_record_set.servis["backend"]: Creation complete after 0s [id=backend.projekat.ruo.lab.]
dns_a_record_set.servis["db"]: Modifications complete after 0s [id=db.projekat.ruo.lab.]
Apply complete! Resources: 1 added, 1 changed, 0 destroyed.
db: 10.61.3.10   backend: 10.61.2.10

== 4. Ponovni plan: bez promjena
  PROŠLO  terraform plan: No changes

Rezultat: 1 prošlo, 0 palo
```
<!-- /IZLAZ:drift -->

## 9. Izmjene tokom odbrane

Sve izmjene idu isključivo kroz kod, pa `make all`:

| Zahtjev | Gdje se mijenja |
|---|---|
| novi DNS zapis | `terraform/dns/main.tf` (novi resurs) → `make dns` |
| nova adresa servisa | `plan-adresa.yaml` (`kontejneri`) → `make dns deploy` |
| memorija/vCPU/disk VM-a | `terraform/vm/variables.tf` ili `terraform.tfvars` (`vm_resursi`) → `make infra` |
| nova VM | `plan-adresa.yaml` (`vm`) + `vm_resursi` → `make all` |
| TTL zone | `plan-adresa.yaml` (`ttl`) → `make dns` |
| izmjena aplikacije | `app/...` → `make deploy` (slike se ponovo grade samo kad se kod promijeni) |

## 10. Mapiranje na obavezne odluke (AO)

| AO | Kako je ispunjena | Provjera |
|---|---|---|
| AO-1 | tri servisa u `app/compose.yaml`, tok frontend → backend → baza | `tests/app.sh`, `tests/izolacija.sh` |
| AO-2 | `make destroy` / `make all`, bez ručnih koraka | odbrana |
| AO-3 | `terraform/vm`: varijable, outputi `ip`, `dns_server`; state u `.gitignore` | `make plan` → No changes |
| AO-4 | `cloud-init/user-data.tftpl`: korisnik `ruo`, SSH ključ, `ssh_pwauth: false`, `lock_passwd` | `common` rola provjerava `sshd -T` |
| AO-5 | 4 role (`common`, `bind`, `docker`, `app`) | `make idempotencija` → changed=0 |
| AO-6 | segmenti `seg-web`/`seg-app`/`seg-db`, `internal`, objavljen samo port 80 | `tests/izolacija.sh` |
| AO-7 | BIND zona `projekat.ruo.lab`; aplikacija koristi samo imena | `tests/dns.sh`, `tests/kod.sh` |
| AO-8 | `terraform/dns`, provider `hashicorp/dns`, TSIG samo za zonu projekta | `tests/dns.sh`, `make drift` |
| AO-9 | ansible-vault, TSIG generisan pri pokretanju, `.gitignore` | `tests/kod.sh` (historija) |
| AO-10 | volume `projekat-pgdata` | `tests/app.sh` (ponovno kreiranje kontejnera baze) |
