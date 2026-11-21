#!/usr/bin/env bash
# AO-6: segmentacija i izolacija slojeva. Negativni testovi (frontend -> baza) MORAJU pasti.
source "$(dirname "$0")/lib.sh"

naslov "Segmenti na app1 (Docker mreže)"
na_app1 "sudo docker network inspect seg-web seg-app seg-db --format '{{.Name}}  {{(index .IPAM.Config 0).Subnet}}  internal={{.Internal}}  kontejneri: {{range .Containers}}{{.Name}} {{end}}'"
jednako "seg-db je internal (bez puta van segmenta)" "$(na_app1 "sudo docker network inspect seg-db --format '{{.Internal}}'")" "true"

naslov "Dozvoljeni tokovi: frontend -> backend -> baza (po DNS imenima)"
ocekuj "frontend -> backend.$ZONA:8000" na_app1 "sudo docker exec frontend nc -z -w 3 backend.$ZONA 8000"
ocekuj "backend  -> db.$ZONA:5432" na_app1 "sudo docker exec backend python -c \"import socket; socket.create_connection(('db.$ZONA', 5432), 3)\""

naslov "Zabranjeni tokovi (moraju pasti)"
ocekuj_pad "frontend -> db.$ZONA:5432 (frontend nema put do baze)" na_app1 "sudo docker exec frontend nc -z -w 3 db.$ZONA 5432"
DB_IP="$(dig +short @"$NS" "db.$ZONA" A)"
ocekuj_pad "frontend -> $DB_IP:5432 (ni direktno po adresi)" na_app1 "sudo docker exec frontend nc -z -w 3 $DB_IP 5432"
ocekuj_pad "baza -> internet (seg-db je internal)" na_app1 "sudo docker exec db wget -q -T 3 -O /dev/null http://deb.debian.org"

naslov "Objavljeni portovi: izvana je dostupan samo frontend"
na_app1 "sudo docker ps --format '  {{.Names}}\t{{.Ports}}'"
jednako "baza nema objavljen port" "$(na_app1 'sudo docker port db')" ""
jednako "backend nema objavljen port" "$(na_app1 'sudo docker port backend')" ""
ocekuj     "host -> app1:80   (frontend)" tcp "$APP1" 80
ocekuj_pad "host -> app1:8000 (backend)"  tcp "$APP1" 8000
ocekuj_pad "host -> app1:5432 (baza)"     tcp "$APP1" 5432

kraj
