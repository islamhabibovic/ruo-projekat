#!/usr/bin/env bash
# Demonstracija drifta u DNS-u (README): zapis kojim upravlja Terraform mijenja se "ručno" (nsupdate,
# mimo koda), terraform plan pokazuje razliku, a terraform apply vraća stanje iz koda.
source "$(dirname "$0")/lib.sh"
KEY="hmac-sha256:tf-projekat:$(cat "$TSIG_SECRET_FILE")"
TF="terraform -chdir=$KORIJEN/terraform/dns"
TF_VAR_tsig_secret="$(cat "$TSIG_SECRET_FILE")"; export TF_VAR_tsig_secret

naslov "1. Ručna izmjena mimo koda: db dobija pogrešnu adresu, backend se briše"
echo "\$ nsupdate: update delete db.$ZONA A; update add db.$ZONA 60 A 10.61.3.99; update delete backend.$ZONA A"
printf 'server %s\nzone %s\nupdate delete db.%s A\nupdate add db.%s 60 A 10.61.3.99\nupdate delete backend.%s A\nsend\n' \
  "$NS" "$ZONA" "$ZONA" "$ZONA" "$ZONA" | nsupdate -y "$KEY"
sleep 1
echo "db: $(dig +short @"$NS" "db.$ZONA")   backend: '$(dig +short @"$NS" "backend.$ZONA")'"

naslov "2. terraform plan otkriva drift"
$TF plan -no-color -input=false | grep -E '^\s+[#~+-]|Plan:|addresses|\+ |\- ' || true

naslov "3. terraform apply vraća stanje iz koda"
$TF apply -auto-approve -no-color -input=false | grep -E 'Apply complete|Modifying|Creating|Modifications complete|Creation complete' || true
echo "db: $(dig +short @"$NS" "db.$ZONA")   backend: $(dig +short @"$NS" "backend.$ZONA")"

naslov "4. Ponovni plan: bez promjena"
$TF plan -no-color -input=false -detailed-exitcode >/dev/null; rc=$?
[ $rc -eq 0 ] && ok "terraform plan: No changes" || greska "terraform plan i dalje ima promjene (kod $rc)"
kraj
