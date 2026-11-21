#!/usr/bin/env bash
# AO-7, AO-8: autoritativni DNS i zapisi servisa. Svi upiti idu direktno na ns1.
source "$(dirname "$0")/lib.sh"
D="dig +short +time=2 +tries=1 @$NS"

naslov "DNS: zona $ZONA na serveru $NS"
echo "\$ dig @$NS $ZONA SOA"; $D "$ZONA" SOA
ocekuj "autoritativni odgovor (flag aa)" bash -c "dig +time=2 @$NS $ZONA SOA | grep -q 'flags:.* aa'"
jednako "NS zapis zone" "$($D "$ZONA" NS)" "ns1.$ZONA."

naslov "Zapisi servisa (terraform/dns)"
for ime in frontend backend db app1 ns1; do
  a="$($D "$ime.$ZONA" A)"
  printf '  %-26s A  %s\n' "$ime.$ZONA" "${a:-<nema>}"
  [ -n "$a" ] && ok "$ime.$ZONA postoji" || greska "$ime.$ZONA ne postoji"
done
jednako "www je CNAME na app1" "$($D "www.$ZONA" CNAME)" "app1.$ZONA."
jednako "www i app1 daju istu adresu" "$($D "www.$ZONA" A | tail -1)" "$($D "app1.$ZONA" A)"
jednako "PTR za app1" "$($D -x "$APP1")" "app1.$ZONA."

naslov "Server je samo autoritativni"
jednako "tuđa domena (example.com): REFUSED" "$(dig +time=2 +tries=1 @$NS example.com A | grep -o 'status: [A-Z]*')" "status: REFUSED"
jednako "nepostojeće ime: NXDOMAIN" "$(dig +time=2 +tries=1 @$NS nema.$ZONA A | grep -o 'status: [A-Z]*')" "status: NXDOMAIN"
ocekuj_pad "prijenos zone (AXFR) je odbijen" bash -c "dig +time=2 @$NS $ZONA AXFR | grep -q 'IN[[:space:]]*SOA'"

naslov "TSIG ključ tf-projekat smije mijenjati SAMO zonu projekta (AO-8)"
KEY="hmac-sha256:tf-projekat:$(cat "$TSIG_SECRET_FILE")"
REV="$(echo "$APP1" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')"
nsup() { nsupdate -y "$KEY" 2>&1; }
izlaz="$(printf 'server %s\nzone %s\nupdate add test-tsig.%s 30 TXT "test"\nsend\n' "$NS" "$ZONA" "$ZONA" | nsup)"
[ -z "$izlaz" ] && ok "UPDATE u zoni $ZONA dozvoljen" || greska "UPDATE u zoni $ZONA: $izlaz"
printf 'server %s\nzone %s\nupdate delete test-tsig.%s TXT\nsend\n' "$NS" "$ZONA" "$ZONA" | nsup >/dev/null
izlaz="$(printf 'server %s\nzone %s\nupdate add 99.%s 30 PTR lazno.%s.\nsend\n' "$NS" "$REV" "$REV" "$ZONA" | nsup)"
echo "  \$ nsupdate (zona $REV) -> ${izlaz:-<bez greške>}"
echo "$izlaz" | grep -q REFUSED && ok "UPDATE u reverznoj zoni odbijen (REFUSED)" || greska "UPDATE u reverznoj zoni NIJE odbijen"
izlaz="$(printf 'server %s\nzone %s\nupdate add x.%s 30 A 127.0.0.1\nsend\n' "$NS" "$ZONA" "$ZONA" | nsupdate 2>&1)"
echo "$izlaz" | grep -q REFUSED && ok "UPDATE bez TSIG ključa odbijen (REFUSED)" || greska "UPDATE bez ključa NIJE odbijen: $izlaz"

kraj
