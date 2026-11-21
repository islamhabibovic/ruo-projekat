# Troslojna aplikacija kao kod: cijeli životni ciklus okruženja.
#   make all      od praznog sistema do aplikacije koja radi (infra -> config -> dns -> deploy)
#   make test     izolacija, dig upiti, aplikacija, kod
#   make destroy  uklanja sve što je projekat kreirao
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.RECIPEPREFIX := >
.DEFAULT_GOAL := help

TFVM   := terraform -chdir=terraform/vm
TFDNS  := terraform -chdir=terraform/dns
TSIG   := .secrets/tsig-tf-projekat.secret
VAULT  := ansible/group_vars/app/vault.yml
SLIKA  := $(HOME)/.cache/projekat/noble-server-cloudimg-amd64.img
SLIKA_URL := https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
export TF_VAR_base_image_url := $(SLIKA)
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help check ssh-key vault slika infra config dns deploy test all destroy drift idempotencija plan dokazi

help: ## ovaj popis
> @grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

check: ## provjera da su svi potrebni alati instalirani
> @rc=0
> for a in terraform ansible-playbook ansible-galaxy ansible-vault virsh ssh dig nsupdate curl python3 openssl; do
>   if command -v $$a >/dev/null; then printf '  %-17s ok\n' $$a; else printf '  %-17s NEDOSTAJE\n' $$a; rc=1; fi
> done
> if virsh -c qemu:///system pool-info default >/dev/null 2>&1; then echo "  libvirt pool       ok"; else echo "  libvirt pool 'default' NEDOSTAJE (00-setup.sh iz repozitorija predmeta)"; rc=1; fi
> [ -e /dev/kvm ] && echo "  /dev/kvm           ok" || { echo "  /dev/kvm           NEDOSTAJE (VM-ovi ne mogu raditi)"; rc=1; }
> exit $$rc

ssh-key: ## SSH ključ administratora (ako ne postoji)
> @[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519

vault: ## lozinka Vaulta i šifrovana lozinka baze (generišu se samo prvi put, nisu u Gitu)
> @umask 077
> [ -f .vault_pass ] || { openssl rand -base64 32 > .vault_pass; echo "napravljen .vault_pass"; }
> if [ ! -f $(VAULT) ]; then
>   printf 'vault_db_password: "%s"\n' "$$(openssl rand -hex 24)" > $(VAULT)
>   ansible-vault encrypt --vault-id default@.vault_pass --encrypt-vault-id default $(VAULT) >/dev/null
>   echo "napravljen i šifrovan $(VAULT)"
> fi

slika: ## bazna cloud slika u lokalnom kešu (preuzima se jednom, ubrzava destroy/all)
> @[ -f $(SLIKA) ] || { mkdir -p $(dir $(SLIKA)); curl -fL --progress-bar -o $(SLIKA).tmp $(SLIKA_URL); mv $(SLIKA).tmp $(SLIKA); }

infra: ssh-key slika ## Terraform: kreiranje mreže i VM-ova (+ inventory za Ansible)
> $(TFVM) init -input=false >/dev/null
> $(TFVM) apply -auto-approve -input=false
> $(TFVM) output

config: vault ## Ansible: osnovna konfiguracija, DNS server (BIND), Docker
> ansible-galaxy collection install -r ansible/requirements.yml >/dev/null
> cd ansible && ansible-playbook site.yml

dns: ## Terraform: DNS zapisi servisa (RFC 2136, TSIG)
> @[ -f $(TSIG) ] || { echo "Nema $(TSIG): prvo make config"; exit 1; }
> $(TFDNS) init -input=false >/dev/null
> TF_VAR_tsig_secret="$$(cat $(TSIG))" $(TFDNS) apply -auto-approve -input=false

deploy: vault ## Ansible: isporuka i pokretanje aplikacije
> cd ansible && ansible-playbook deploy.yml

test: ## test izolacije, dig upiti, provjera aplikacije, provjera koda
> @rc=0
> for t in dns izolacija app kod; do bash tests/$$t.sh || rc=1; done
> [ $$rc -eq 0 ] && printf '\n\033[1;32mSVI TESTOVI SU PROŠLI\033[0m\n' || { printf '\n\033[1;31mNEKI TESTOVI SU PALI\033[0m\n'; exit 1; }

all: infra config dns deploy ## svi koraci redom, od praznog sistema do aplikacije koja radi

plan: ## terraform plan za VM-ove i DNS (očekuje se: No changes)
> $(TFVM) plan -input=false -detailed-exitcode
> TF_VAR_tsig_secret="$$(cat $(TSIG))" $(TFDNS) plan -input=false -detailed-exitcode

idempotencija: ## drugo izvršavanje: Ansible changed=0 i Terraform bez promjena
> @mkdir -p docs/izlazi
> cd ansible && ansible-playbook site.yml deploy.yml | tee ../docs/izlazi/ansible-drugo-izvrsavanje.txt
> cd ..
> grep -E '^\S+\s+:' docs/izlazi/ansible-drugo-izvrsavanje.txt | grep -vq 'changed=0' && { echo "NIJE idempotentno"; exit 1; } || echo "Ansible: changed=0 na svim hostovima"
> $(MAKE) --no-print-directory plan

drift: ## demonstracija drifta DNS zapisa: nsupdate mimo koda, plan, apply
> bash tests/drift.sh

dokazi: ## izlazi za README: idempotentnost, testovi, drift (upisuju se u README.md)
> bash tests/dokazi.sh

destroy: ## uklanja DNS zapise, VM-ove, mrežu, diskove, inventory i lokalnu TSIG tajnu
> if [ -f terraform/dns/terraform.tfstate ] && [ -f $(TSIG) ] && TF_VAR_tsig_secret="$$(cat $(TSIG))" timeout 60 $(TFDNS) destroy -auto-approve -input=false; then :; else
>   echo "DNS server nije dostupan: zapisi nestaju zajedno s ns1, brišem samo state"; rm -f terraform/dns/terraform.tfstate*
> fi
> [ -d terraform/vm/.terraform ] && $(TFVM) destroy -auto-approve -input=false || true
> rm -f ansible/inventory.ini $(TSIG)
