#!/usr/bin/env bash
# Zajedničke funkcije testova. Adrese se čitaju iz Terraform outputa i plan-adresa.yaml, ne pišu se ručno.
# shellcheck disable=SC2034  # varijable koriste skripte koje uključuju ovu datoteku
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
KORIJEN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZONA="$(awk '/^zona:/{print $2}' "$KORIJEN/plan-adresa.yaml")"
ADMIN="${ADMIN:-ruo}"
if [ -z "${BEZ_INFRA:-}" ]; then
  NS="$(terraform -chdir="$KORIJEN/terraform/vm" output -raw dns_server)" || { echo "Nema infrastrukture: make infra"; exit 1; }
  APP1="$(terraform -chdir="$KORIJEN/terraform/vm" output -json ip | python3 -c 'import json,sys; print(json.load(sys.stdin)["app1"])')"
fi
TSIG_SECRET_FILE="$KORIJEN/.secrets/tsig-tf-projekat.secret"

PROSLO=0; PALO=0
naslov() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()     { printf '  \033[32mPROŠLO\033[0m  %s\n' "$*"; PROSLO=$((PROSLO + 1)); }
greska() { printf '  \033[31mPALO\033[0m    %s\n' "$*"; PALO=$((PALO + 1)); }

# ocekuj "opis" naredba...      -> naredba mora uspjeti
ocekuj()       { local o="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$o"; else greska "$o"; fi; }
# ocekuj_pad "opis" naredba...  -> naredba MORA pasti (negativni test)
ocekuj_pad()   { local o="$1"; shift; if "$@" >/dev/null 2>&1; then greska "$o"; else ok "$o"; fi; }
# jednako "opis" stvarno ocekivano
jednako() { if [ "$2" = "$3" ]; then ok "$1  [$2]"; else greska "$1  [dobijeno: '$2', očekivano: '$3']"; fi; }

# naredba na app1 preko SSH-a
na_app1() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
      "$ADMIN@$APP1" "$@"
}

# TCP konekcija s hosta (bez nc): uspjeh ako se port otvori za 3 s
tcp() { timeout 3 bash -c "</dev/tcp/$1/$2"; }

kraj() {
  printf '\nRezultat: %d prošlo, %d palo\n' "$PROSLO" "$PALO"
  [ "$PALO" -eq 0 ]
}
