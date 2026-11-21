#!/usr/bin/env bash
# AO-7: komponente se adresiraju isključivo DNS imenima. U kodu aplikacije (app/) ne smije biti IP adresa;
# adrese postoje samo u planu adresiranja (plan-adresa.yaml), odakle ih čitaju Terraform i Ansible.
# AO-9: u Gitu nema tajni ni stanja.
cd "$(dirname "$0")/.." || exit 1
BEZ_INFRA=1 source tests/lib.sh

naslov "IP adrese u kodu aplikacije (app/)"
# 127.0.0.1 i 0.0.0.0 (healthcheck unutar kontejnera i "slušaj na svim sučeljima") nisu adrese komponenti
nadjeno="$(grep -rnE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' app/ | grep -vE '\b(127\.0\.0\.1|0\.0\.0\.0)\b' || true)"
[ -z "$nadjeno" ] && ok "app/ ne sadrži nijednu adresu komponente (samo DNS imena)" || { greska "IP adrese u app/:"; echo "$nadjeno"; }

naslov "Datoteke koje ne smiju biti u Gitu (AO-9)"
if git rev-parse --git-dir >/dev/null 2>&1; then
  zabranjeno="$(git log --all --name-only --pretty=format: | sort -u | grep -E '(\.tfstate|\.terraform/|(^|/)\.env$|\.vault_pass|\.secrets/|vault\.yml$|inventory\.ini|id_ed25519$|\.key$)' || true)"
  [ -z "$zabranjeno" ] && ok "historija Gita ne sadrži state, .env, vault lozinku, ključeve ni inventory" || { greska "u historiji Gita:"; echo "$zabranjeno"; }
else
  echo "  (nije Git repozitorij, preskačem)"
fi

kraj
