# terraform/dns: DNS zapisi servisa kao Terraform resursi (AO-8), na osnovu s5/p2.
# Provider hashicorp/dns šalje izmjene BIND serveru na ns1 protokolom RFC 2136 (dinamički UPDATE),
# potpisane TSIG ključem "tf-projekat". BIND dozvoljava tom ključu izmjene SAMO u zoni projekta
# (update-policy u ansible/roles/bind). Statički dio zone (SOA, NS, ns1) postavlja Ansible.

terraform {
  required_version = ">= 1.5"
  required_providers {
    dns = { source = "hashicorp/dns", version = "~> 3.4" }
  }
}

variable "tsig_secret" {
  description = "TSIG tajna ključa tf-projekat (Makefile je čita iz .secrets/, gdje je Ansible spremi)"
  type        = string
  sensitive   = true
}

variable "tsig_key_name" {
  type    = string
  default = "tf-projekat."
}

locals {
  plan = yamldecode(file("${path.module}/../../plan-adresa.yaml"))
  zona = "${local.plan.zona}."
  ttl  = local.plan.ttl

  # servisi (kontejneri): adresa na segmentu na kojem servis prima zahtjeve
  servisi = { for ime, k in local.plan.kontejneri : ime => k.adrese[k.segment] }

  # VM-ovi koji nisu DNS server (ns1 je u statičkom dijelu zone kao "glue" za NS)
  vm = { for ime, v in local.plan.vm : ime => v.ip if v.grupa != "dns" }
}

provider "dns" {
  update {
    server        = local.plan.vm.ns1.ip
    key_name      = var.tsig_key_name
    key_algorithm = "hmac-sha256"
    key_secret    = var.tsig_secret
  }
}

# frontend, backend, db -> adrese kontejnera na njihovim segmentima (unutrašnja imena)
resource "dns_a_record_set" "servis" {
  for_each  = local.servisi
  zone      = local.zona
  name      = each.key
  addresses = [each.value]
  ttl       = local.ttl
}

# virtuelne mašine aplikacije (app1)
resource "dns_a_record_set" "vm" {
  for_each  = local.vm
  zone      = local.zona
  name      = each.key
  addresses = [each.value]
  ttl       = local.ttl
}

# javni ulaz: www pokazuje na VM na kojoj frontend objavljuje port 80
resource "dns_cname_record" "www" {
  zone  = local.zona
  name  = "www"
  cname = "app1.${local.zona}"
  ttl   = local.ttl
}

resource "dns_txt_record_set" "vlasnik" {
  zone = local.zona
  txt  = ["zapise servisa upravlja terraform/dns"]
  ttl  = local.ttl
}

output "imena" {
  value = merge(
    { for k, r in dns_a_record_set.servis : "${k}.${local.zona}" => r.addresses },
    { for k, r in dns_a_record_set.vm : "${k}.${local.zona}" => r.addresses },
    { "www.${local.zona}" = ["CNAME ${dns_cname_record.www.cname}"] },
  )
}
