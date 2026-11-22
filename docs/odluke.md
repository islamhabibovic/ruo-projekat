---
title: "Troslojna aplikacija kao kod"
subtitle: "Dizajnerske odluke (DO-1 do DO-9) i zapisi arhitektonskih odluka (ADR)"
---

| | |
|---|---|
| **Student** | Islam Habibović |
| **Predmet** | Računarstvo u oblaku, II ciklus, III semestar, 2026/27 |
| **Nastavnik / asistent** | V. prof. dr. Đulaga Hadžić / ass. Mr. Adin Jahić |
| **Git repozitorij** | https://github.com/islamhabibovic/ruo-projekat |
| **Datum predaje** | 25.11.2026. |

# 1. Kratak opis aplikacije i arhitekture

**Aplikacija.** "Bilješke" je mala vlastita web aplikacija za unos, pregled i brisanje kratkih bilješki.
Frontend je nginx koji poslužuje statičnu stranicu i prosljeđuje `/api/` backendu; backend je Flask REST API
(gunicorn, psycopg 3); baza je PostgreSQL 16 s podacima u Docker volumenu. Aplikacija je namjerno jednostavna,
jer se ocjenjuje infrastruktura, ali prolazi kroz sva tri sloja.

**Arhitektura.** Terraform (provider `dmacvicar/libvirt`) pravi libvirt mrežu `projekat` (10.60.0.0/24, NAT)
i dvije virtuelne mašine iz službene Ubuntu 24.04 cloud slike: `ns1` (10.60.0.53) s autoritativnim BIND
serverom i `app1` (10.60.0.10) s Dockerom. cloud-init na obje pravi korisnika `ruo` sa SSH ključem i
isključuje prijavu lozinkom. Ansible (role `common`, `bind`, `docker`, `app`) konfiguriše servere i isporučuje
aplikaciju. Na `app1` su slojevi aplikacije u tri Docker mreže s fiksnim podmrežama (`seg-web` 10.61.1.0/24,
`seg-app` 10.61.2.0/24, `seg-db` 10.61.3.0/24, `internal`); izvana je objavljen samo port 80 frontenda.
Zona `projekat.ruo.lab` je na `ns1`; zapise servisa (`frontend`, `backend`, `db`, `app1`, `www`) održava
Terraform (provider `hashicorp/dns`, RFC 2136) TSIG ključem koji smije mijenjati samo tu zonu. Komponente se
međusobno adresiraju isključivo tim imenima. Cijeli životni ciklus vodi `Makefile`
(`make all`, `make test`, `make destroy`).

Sve adrese su na jednom mjestu, u datoteci `plan-adresa.yaml`, koju čitaju i Terraform i Ansible.

# 2. Pregled dizajnerskih odluka

| ID | Pitanje | Izabrana opcija |
|---|---|---|
| DO-1 | Aplikacija i tehnologije | vlastita aplikacija "Bilješke": nginx 1.27 · Python 3.12/Flask/gunicorn · PostgreSQL 16 |
| DO-2 | Broj VM-ova i raspored | varijanta A: `app1` (sva tri kontejnera, segmenti kao Docker mreže) + zasebna `ns1` za DNS |
| DO-3 | Plan adresiranja | libvirt 10.60.0.0/24 sa statičkim DHCP rezervacijama; segmenti 10.61.{1,2,3}.0/24 sa statičkim adresama kontejnera; sve u `plan-adresa.yaml` |
| DO-4 | Bazna slika VM-a | službena Ubuntu 24.04 cloud slika + cloud-init, keširana lokalno |
| DO-5 | Slike kontejnera | build na ciljnoj VM (Compose), multi-stage Dockerfile za backend, rebuild samo kad se kod promijeni |
| DO-6 | Adrese VM-ova za Ansible | inventory generisan iz stanja Terraforma (`local_file`) |
| DO-7 | Ansible role i varijable | role po funkciji (`common`, `bind`, `docker`, `app`); `defaults` u rolama, tajne u `group_vars/app` + Vault, adrese iz `plan-adresa.yaml` |
| DO-8 | DNS zona | `projekat.ruo.lab`, TTL 60 s, statički dio Ansible / zapisi servisa Terraform, PTR za VM-ove, bez sekundarnog servera |
| DO-9 | Upravljanje tajnama | ansible-vault za lozinku baze (generiše se), TSIG generisan na serveru, Docker secret umjesto varijable okruženja |

# 3. Zapisi arhitektonskih odluka (ADR)

## DO-1: Aplikacija i tehnologije slojeva

**Status:** prihvaćeno

### Kontekst
Treba troslojna aplikacija čija je svaka komponenta u svom kontejneru, s tokom isključivo
frontend → backend → baza (AO-1), čiji podaci preživljavaju ponovno kreiranje kontejnera baze (AO-10) i koja
druge komponente nalazi po DNS imenu (AO-7). Aplikacija se ne ocjenjuje, pa je važno da bude dovoljno mala da
se na odbrani svaki fajl može objasniti, a da ipak stvarno koristi sva tri sloja.

### Razmotrene opcije
1. Gotov open-source projekat (npr. aplikacija za zadatke s React frontendom i Node backendom).
2. Proširenje primjera `s3/p4` (Flask + Redis brojač posjeta).
3. Vlastita mala aplikacija: nginx (statična stranica + reverse proxy), Flask API, PostgreSQL.
4. Kao 3, ali s MongoDB ili MySQL bazom.

### Odluka
Opcija 3: aplikacija "Bilješke" s nginx frontendom, Flask/gunicorn backendom i PostgreSQL 16 bazom.

### Obrazloženje i posljedice
Gotov projekat donosi stotine fajlova i zavisnosti koje ne bih znao objasniti red po red, a često ima vlastite
pretpostavke o mreži (npr. tvrdo upisane hostove). Redis iz `s3/p4` nije prava relaciona baza i ne pokazuje
tipičan problem trajnosti podataka. Vlastita aplikacija ima oko 100 linija koda, a pokriva sve što
infrastruktura treba pokazati: frontend koji je jedini ulaz i proxy prema backendu, backend koji jedini
razgovara s bazom, te bazu s volumenom. PostgreSQL ima službenu sliku s podrškom za lozinku iz datoteke
(`POSTGRES_PASSWORD_FILE`), što direktno služi DO-9, i `pg_isready` za healthcheck. nginx frontend omogućava
da se backend razrješava preko DNS-a pri svakom zahtjevu (`resolver` + varijabla u `proxy_pass`), pa izmjena
DNS zapisa ne traži restart. Gubitak: aplikacija nema autentifikaciju ni HTTPS, što za lab nije bitno, i nije
reprezentativna za opterećenje produkcijske aplikacije.

## DO-2: Broj VM-ova i raspored komponenti

**Status:** prihvaćeno

### Kontekst
AO-6 traži da svaki sloj bude u svom segmentu s vlastitom podmrežom, da je izvana dostupan samo frontend i da
frontend nema mrežni put do baze; način izvedbe je slobodan. AO-7 traži autoritativni BIND, AO-3 da VM-ove
kreira Terraform. Ograničenje je računar studenta (WSL2 s ugniježđenom virtualizacijom i ograničenom memorijom)
i to da se na odbrani cijelo okruženje uklanja i ponovo podiže.

### Razmotrene opcije
1. **A:** jedna VM s Dockerom; segmenti su Docker mreže s fiksnim podmrežama, kontejner je samo na mrežama
   koje mu trebaju. DNS na istoj VM.
2. **A s DNS-om na zasebnoj VM:** kao 1, ali BIND je na posebnoj, maloj VM.
3. **B:** po jedna VM za svaki segment na libvirt mrežama u route modu, host usmjerava i filtrira (nftables).

### Odluka
Opcija 2: `app1` (frontend, backend, baza kao kontejneri, segmenti kao Docker mreže) i `ns1` (BIND).

### Obrazloženje i posljedice
Varijanta B najvjernije oponaša fizičku segmentaciju, ali traži četiri VM-a (tri sloja + DNS), više od 4 GB
memorije i pravila prosljeđivanja na hostu, koja u WSL2 interferiraju s Dockerom i libvirt NAT-om; podizanje
od nule bi trajalo znatno duže, a svaki ponovni pokušaj na odbrani je skup. Varijanta A postiže istu
izolaciju unutar jedne VM: Docker između različitih bridge mreža ne prosljeđuje promet, segment baze je
`internal` (bez gatewaya), a frontend nema sučelje u segmentu baze, pa ne postoji ni ruta. Izolacija se
dokazuje testom, a ne samo tvrdi. DNS je izdvojen na `ns1` jer ima drugačiji životni ciklus od aplikacije: Terraform
DNS provider se spaja direktno na stabilnu adresu VM-a (bez objavljivanja porta 53 iz kontejnera), BIND radi
kao servis operativnog sistema s AppArmor profilom, a ponovna isporuka aplikacije ne dira DNS. Gubitak: svi
slojevi dijele jedno jezgro i jedan Docker daemon, pa kompromitovan host ili Docker poništava segmentaciju;
izolacija se oslanja na pravila koja Docker sam održava, a ne na vlastiti vatrozid. Za produkciju bi se
prešlo na B ili na odvojene mreže u oblaku sa sigurnosnim grupama.

## DO-3: Plan adresiranja

**Status:** prihvaćeno

### Kontekst
Svaki segment mora imati vlastitu podmrežu (AO-6), adrese VM-ova su Terraform outputi (AO-3), a DNS zapisi
servisa moraju pokazivati na stvarne adrese (AO-7, AO-8). Ista adresa se koristi u tri alata (Terraform za VM,
Terraform za DNS, Ansible za Compose), pa postoji rizik da se kopije raziđu. Podmreže se ne smiju preklapati s
mrežama hosta (WSL2 172.16.0.0/12, libvirt `default` 192.168.122.0/24, Docker `docker0` 172.17.0.0/16).

### Razmotrene opcije
1. Dinamičke adrese (DHCP za VM-ove, IPAM Dockera za kontejnere), DNS zapisi se popunjavaju iz outputa.
2. Statičke adrese upisane direktno u svaki alat (tfvars, group_vars, compose).
3. Statičke adrese u jednoj datoteci (`plan-adresa.yaml`) koju čitaju svi alati; VM-ovi preko DHCP
   rezervacije u libvirt mreži, kontejneri preko `ipv4_address`.

### Odluka
Opcija 3. libvirt mreža 10.60.0.0/24 (host .1, `app1` .10, `ns1` .53); segmenti 10.61.1.0/24 (web),
10.61.2.0/24 (app), 10.61.3.0/24 (db), servis na svom segmentu ima adresu .10, a druga sučelja višeg
(.20). Sve u `plan-adresa.yaml`.

### Obrazloženje i posljedice
Dinamičke adrese bi tražile da se DNS zapisi pišu tek nakon što Docker dodijeli adrese, što lomi redoslijed
`dns` prije `deploy` i čini plan zavisnim od stanja kontejnera. Kopiranje adresa u više alata je glavni izvor
grešaka. S jednim izvorom istine Terraform čita plan funkcijom `yamldecode`, Ansible ga učitava kao
`vars_files`, a `.env` za Compose generiše Ansible, pa u `compose.yaml` i kodu aplikacije nema nijedne IP
adrese. Raspon 10.60–10.61 je izvan svih mreža koje WSL2, Docker i libvirt koriste po defaultu, a
predvidljive adrese (.10 servis, .53 DNS) olakšavaju dijagnostiku na odbrani. Rezervacija u libvirt DHCP-u
daje statičku adresu bez konfiguracije mreže u gostu (cloud slika ostaje na DHCP-u). Gubitak: izmjena adrese
traži ponovnu isporuku (`make dns deploy`), a plan je ručno održavan, pa je moguća greška preklapanja
adresa, koju bi u većem sistemu sprječavao IPAM.

## DO-4: Bazna slika VM-a

**Status:** prihvaćeno

### Kontekst
AO-4 propisuje da početnu konfiguraciju radi cloud-init (korisnik, SSH ključ, bez lozinke), a AO-2 da se
okruženje podiže bez ručnih koraka. Na odbrani se okruženje uklanja i podiže od nule, pa je bitno vrijeme
podizanja.

### Razmotrene opcije
1. Službena Ubuntu 24.04 cloud slika + cloud-init, a sav softver instalira Ansible.
2. Vlastita slika izgrađena Packerom (`s2/p4`) s već instaliranim Dockerom i BIND-om.
3. Cloud slika + cloud-init koji instalira i sav softver (bez Ansiblea za osnovne pakete).

### Odluka
Opcija 1, uz lokalni keš slike (`make slika` je preuzme jednom u `~/.cache/projekat`, a Terraform je
učitava kao `source` bazne zapremine).

### Obrazloženje i posljedice
Službena slika je održavana, potpisana i mala (oko 600 MB), a cloud-init je u njoj već prisutan. Packer slika
bi skratila podizanje za instalaciju paketa, ali dodaje još jedan alat, build od nekoliko minuta i odgovornost
za ažuriranje slike; tada bi dio konfiguracije bio "zapečen" u slici, a dio u Ansibleu, pa bi bilo teže
dokazati idempotentnost. Ako bi cloud-init instalirao sav softver, ta konfiguracija se izvršava samo pri
prvom bootu i nema provjere drifta. Zato cloud-init radi samo bootstrap (korisnik, SSH, `python3`), a sve
ostalo Ansible. Lokalni keš znači da `make destroy` ne briše preuzetu sliku, pa ponovno podizanje ne čeka
preuzimanje. Gubitak: svako podizanje instalira pakete iz mreže (nekoliko minuta i zavisnost od dostupnosti
repozitorija), a `current` slika se mijenja s vremenom, pa dva podizanja u razmaku nisu bit-identična.

## DO-5: Gradnja i distribucija slika kontejnera

**Status:** prihvaćeno

### Kontekst
Frontend i backend su vlastiti kod s Dockerfileovima, baza je službena slika. Slike moraju nastati iz koda
(AO-2), a drugo izvršavanje isporuke mora biti bez promjena (AO-5). U okruženju nema registryja.

### Razmotrene opcije
1. Build na ciljnoj VM (`docker compose build`) iz koda koji Ansible kopira.
2. Build lokalno na hostu, push u registry (Docker Hub ili lokalni), pull na VM.
3. Build lokalno, `docker save`/`docker load` preko SSH-a.

### Odluka
Opcija 1, s multi-stage Dockerfileom za backend (faza instalacije zavisnosti i mala finalna slika s
neprivilegovanim korisnikom). Ansible gradi slike (`build: always`) samo kad se kopirani kod promijenio, a
inače samo ako slika ne postoji (`build: policy`).

### Obrazloženje i posljedice
Registry bi bio još jedna komponenta koju treba podići, osigurati i za koju trebaju kredencijali (nova
tajna), a javni registry bi zahtijevao nalog. Build na VM-u ne traži Docker na hostu i koristi isti Docker
koji pokreće kontejnere, pa nema razlike u arhitekturi slike. Multi-stage build drži alate za instalaciju
izvan finalne slike, a `HEALTHCHECK` omogućava da Compose pokreće slojeve redom (`depends_on: service_healthy`).
Uslovni rebuild čuva idempotentnost: drugo izvršavanje ne gradi ništa i ne mijenja kontejnere. Gubitak: build
troši resurse VM-a i ponavlja se na svakoj VM (s više instanci bi registry bio bolji), a slike nisu potpisane
ni verzionisane po commitu, već po varijabli `app_verzija`.

## DO-6: Kako Ansible dobija adrese VM-ova

**Status:** prihvaćeno

### Kontekst
VM-ove kreira Terraform (AO-3), a konfiguriše ih Ansible (AO-5). Ansible mora znati adrese i grupe hostova
bez ručnog prepisivanja (AO-2).

### Razmotrene opcije
1. Ručni `inventory.ini` u Gitu.
2. Inventory generisan iz Terraforma kao resurs (`local_file`), po uzoru na `s3/p3`.
3. Dinamički inventory plugin (npr. `community.libvirt.libvirt` ili čitanje `terraform output -json`).

### Odluka
Opcija 2: `terraform/vm` generiše `ansible/inventory.ini` iz stvarnih adresa domena i polja `grupa` iz plana
(`dns` → `ns1`, `app` → `app1`); datoteka nije u Gitu.

### Obrazloženje i posljedice
Ručni inventory je kopija adresa koja zastari čim se plan promijeni. Dinamički plugin je elegantan, ali
dodaje kolekciju i konfiguraciju koju na odbrani treba objasniti, a libvirt plugin bi se spajao preko
`qemu+ssh`/agenta i ne vidi Ansible grupe. Generisani inventory je jednostavan, čitljiv i ima isti životni
ciklus kao VM-ovi: nastaje pri `apply`, briše se pri `destroy`, a ako se VM promijeni, Terraform ga ponovo
piše. Grupe dolaze iz istog plana kao i adrese. Gubitak: inventory postoji samo na računaru koji drži
Terraform state, pa za timski rad treba udaljeni state ili dinamički inventory.

## DO-7: Organizacija Ansible rola i varijabli

**Status:** prihvaćeno

### Kontekst
Konfiguraciju radi Ansible organizovan u role, a playbook mora biti idempotentan (AO-5). Iste adrese koristi i
Terraform (DO-3), a tajne ne smiju biti u čistom obliku (AO-9).

### Razmotrene opcije
1. Rola po komponenti aplikacije (frontend, backend, db), svaka sa svojim Docker zadacima.
2. Rola po funkciji servera: `common` (svi), `bind` (DNS), `docker` (Docker host), `app` (isporuka).
3. Jedan veliki playbook bez rola.

### Odluka
Opcija 2. Dva playbooka: `site.yml` (konfiguracija servera) i `deploy.yml` (isporuka aplikacije), što
odgovara ciljevima `make config` i `make deploy`. Podesive vrijednosti uloge su u `defaults/main.yml`
(npr. `app_dir`, `bind_tsig_kljuc`), zajednički plan adresa je `vars_files: ../plan-adresa.yaml`, a
`group_vars/app` drži samo vezu na tajnu (`db_password: "{{ vault_db_password }}"`) i šifrovani `vault.yml`.

### Obrazloženje i posljedice
Aplikacija se pokreće kao jedan Compose projekat, pa bi tri role po komponenti dijelile isti `compose.yaml` i
međusobno zavisile; uloga po funkciji odgovara tome šta se na serveru stvarno instalira. `defaults` imaju
najniži prioritet, pa se mogu pregaziti iz `group_vars` bez izmjene role. Idempotentnost je postignuta
modulima koji porede stanje (`apt`, `template`, `copy`, `docker_compose_v2`), `creates:` za generisanje TSIG
ključa, `force: false` za početni sadržaj dinamičke zone (da Ansible ne pregazi zapise Terraforma) i
`changed_when: false` za provjere. Gubitak: plan adresa nije u `group_vars`, nego se učitava eksplicitno u
svakom playu, a `deploy.yml` pretpostavlja da je `site.yml` već izvršen (redoslijed garantuje Makefile).

## DO-8: Projekat DNS zone

**Status:** prihvaćeno

### Kontekst
Projekat ima vlastitu autoritativnu zonu (AO-7), zapisi servisa su Terraform resursi, a TSIG ključ smije
mijenjati samo zonu projekta (AO-8). Na odbrani se traži novi zapis kroz kod i demonstracija drifta.

### Razmotrene opcije
1. Statička zona u Gitu (Ansible template) za sve zapise.
2. Dinamička zona: statički dio (SOA, NS, `ns1`) postavlja Ansible jednom, zapise servisa Terraform.
3. Kao 2, uz sekundarni server i round-robin za više instanci frontenda.

### Odluka
Opcija 2. Zona `projekat.ruo.lab`, TTL 60 s; Terraform održava `frontend`, `backend`, `db`, `app1`, `www`
(CNAME na `app1`) i TXT oznaku vlasnika; reverzna zona `0.60.10.in-addr.arpa` (PTR za VM-ove) je statička i
nema `update-policy`. Server je samo autoritativni (`recursion no`, AXFR zabranjen, upiti samo iz mreže
projekta). Nema sekundarnog servera.

### Obrazloženje i posljedice
Statička zona ne ispunjava AO-8 i miješa dva vlasnika istog fajla. U opciji 2 svaki zapis ima tačno jednog
vlasnika: `ns1` je potreban prije nego što Terraform može raditi (glue za NS), pa ga postavlja Ansible, a sve
ostalo je resurs s planom, stanjem i detekcijom drifta. `force: false` sprječava da Ansible pri drugom
izvršavanju prepiše zonu koju BIND u međuvremenu ažurira. Kratki TTL (60 s) skraćuje vrijeme u kojem keš
drži staru adresu nakon izmjene, što je bitno za demonstraciju i za nginx, koji ime razrješava pri svakom
zahtjevu. `update-policy ... zonesub ANY` je najmanje pravo koje Terraformu treba, a reverzna zona bez
politike dokazuje da ključ ne može van svoje zone. `www` je CNAME jer javni ulaz prati VM, a ne kontejner.
Sekundarni server i round-robin su izostavljeni jer postoji po jedna instanca svakog servisa; ns1 je zato
jedna tačka otkaza za razrješavanje imena unutar aplikacije. Interni zapisi (`db`, `backend`) su vidljivi
svakome ko smije slati upite, što je prihvatljivo jer su upiti ograničeni na mrežu projekta.

## DO-9: Upravljanje tajnama

**Status:** prihvaćeno

### Kontekst
Tajne (lozinka baze, TSIG ključ, privatni ključevi) nikad ne smiju biti u Gitu u čistom obliku, a tajna koja
je jednom ušla u historiju smatra se otkrivenom (AO-9). Istovremeno, podizanje mora ostati bez ručnih koraka
(AO-2).

### Razmotrene opcije
1. `.env` s lozinkom van Gita, koji student ručno pravi.
2. ansible-vault: šifrovana datoteka s lozinkom baze; Vault lozinka van Gita.
3. Generisanje pri prvom pokretanju, bez ikakve trajne kopije.

### Odluka
Kombinacija prema vrsti tajne:

- **lozinka baze:** `make vault` je generiše nasumično (`openssl rand`) i šifruje ansible-vault-om u
  `group_vars/app/vault.yml`; Vault lozinka je u `.vault_pass` (0600). Obje datoteke su van Gita, u Gitu je samo
  `vault.yml.example`. Na VM-u lozinka ide u `secrets/db_password` (direktorij 0700), a u kontejnere kao
  **Docker secret** (`POSTGRES_PASSWORD_FILE`, `DB_PASSWORD_FILE`), ne kao varijabla okruženja;
- **TSIG ključ:** generiše ga Ansible na `ns1` (`tsig-keygen`, samo ako ne postoji), a lokalnu kopiju za
  Terraform drži u `.secrets/` (0600). Terraform ga prima kroz osjetljivu varijablu (`sensitive = true`);
- **SSH ključ:** ostaje u `~/.ssh`, VM dobija samo javni ključ.

### Obrazloženje i posljedice
Ručno pravljen `.env` je ručni korak i ne može se dijeliti sigurno. Ansible-vault je alat iz nastave, radi
bez dodatne infrastrukture i omogućava da šifrovana datoteka u budućnosti uđe u Git (npr. za timski rad) bez
otkrivanja vrijednosti. TSIG ključ nema smisla čuvati trajno jer vrijedi samo za konkretan server; generisan
na serveru, nikad ne putuje u čistom obliku kroz repozitorij. Docker secret se ne vidi u `docker inspect`
ni u okruženju procesa, za razliku od varijable okruženja. Testom `tests/kod.sh` provjerava se cijela
historija Gita. Gubitak: Vault lozinka i lokalni TSIG su obične datoteke na disku administratora, pa je
njihova zaštita prepuštena pravima pristupa (Terraform state je također van Gita). Rotacija lozinke baze traži i izmjenu lozinke u PostgreSQL-u, jer
`POSTGRES_PASSWORD_FILE` važi samo pri prvoj inicijalizaciji volumena. Za produkciju bi se koristio
centralni sistem za tajne (npr. HashiCorp Vault) s rotacijom.
