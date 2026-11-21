#!/usr/bin/env bash
# AO-1, AO-10: aplikacija odgovara kroz sva tri sloja i podaci baze preživljavaju ponovno kreiranje kontejnera.
source "$(dirname "$0")/lib.sh"
WWW="$(dig +short @"$NS" "www.$ZONA" A | tail -1)"
URL="http://$WWW"
echo "www.$ZONA -> $WWW (razriješeno na ns1)"

naslov "Aplikacija kroz frontend (jedini ulaz)"
jednako "GET / (frontend)" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: www.$ZONA" "$URL/")" "200"
zdr="$(curl -s "$URL/api/health/db")"; echo "  $zdr"
ocekuj "frontend -> backend -> baza (/api/health/db)" grep -q '"status":"ok"' <<<"$zdr"

naslov "AO-10: podaci preživljavaju ponovno kreiranje kontejnera baze"
OZNAKA="test-postojanosti-$(date +%s)"
odg="$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"tekst\":\"$OZNAKA\"}" "$URL/api/biljeske")"
echo "  POST: $odg"
ocekuj "bilješka upisana" grep -q "$OZNAKA" <<<"$odg"
ID_PRIJE="$(na_app1 'sudo docker inspect -f {{.Id}} db' | cut -c1-12)"
echo "  \$ docker compose rm -sf db && docker compose up -d --wait db"
na_app1 "cd /opt/projekat && sudo docker compose rm -sf db >/dev/null 2>&1 && sudo docker compose up -d --wait db >/dev/null 2>&1"
ID_POSLIJE="$(na_app1 'sudo docker inspect -f {{.Id}} db' | cut -c1-12)"
echo "  kontejner baze: $ID_PRIJE -> $ID_POSLIJE"
[ "$ID_PRIJE" != "$ID_POSLIJE" ] && ok "kontejner baze je novi" || greska "kontejner baze nije ponovo kreiran"
ocekuj "bilješka postoji nakon ponovnog kreiranja" bash -c "curl -s '$URL/api/biljeske' | grep -q '$OZNAKA'"
ID="$(grep -o '"id":[0-9]*' <<<"$odg" | cut -d: -f2)"
[ -n "$ID" ] && curl -s -X DELETE "$URL/api/biljeske/$ID" >/dev/null

kraj
