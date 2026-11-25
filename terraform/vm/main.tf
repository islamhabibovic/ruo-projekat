# terraform/vm: virtuelne mašine i mreža projekta (AO-3), na osnovu s2/p3 i s3/p3.
#
#   libvirt mreža "projekat" (NAT, 10.60.0.0/24)  ──  ns1  (BIND, autoritativni DNS)
#                                                  └─ app1 (Docker: frontend, backend, baza)
#
# Adrese i raspored dolaze iz ../../plan-adresa.yaml (jedini izvor istine), resursi VM-ova su
# varijable (variables.tf), a adrese su outputi (outputs.tf). State je lokalan i NIJE u Gitu.

terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = { source = "dmacvicar/libvirt", version = "~> 0.8.3" }
    local   = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

locals {
  plan = yamldecode(file("${path.module}/../../plan-adresa.yaml"))
  vms  = local.plan.vm
}

# vlastita mreža projekta: NAT prema internetu (paketi, Docker slike), host je prva adresa podmreže.
# dnsmasq libvirta ostaje resolver VM-ova za internet; zonu projekta služi BIND na ns1.
resource "libvirt_network" "projekat" {
  name      = local.plan.libvirt_mreza.ime
  mode      = "nat"
  addresses = [local.plan.libvirt_mreza.podmreza]
  autostart = true

  dhcp {
    enabled = true
  }
  dns {
    enabled = true
  }
}

# bazna slika (DO-4): službena Ubuntu cloud slika, preuzima se jednom
resource "libvirt_volume" "base" {
  name   = "projekat-ubuntu-noble-base.qcow2"
  pool   = var.storage_pool
  format = "qcow2"
  source = startswith(var.base_image_url, "http") ? var.base_image_url : pathexpand(var.base_image_url)
}

# disk svake VM je copy-on-write potomak bazne slike
resource "libvirt_volume" "disk" {
  for_each       = local.vms
  name           = "projekat-${each.key}.qcow2"
  pool           = var.storage_pool
  format         = "qcow2"
  base_volume_id = libvirt_volume.base.id
  size           = var.vm_resursi[each.key].disk_gb * 1024 * 1024 * 1024
}

# cloud-init (AO-4): samo bootstrap, korisnik za upravljanje + SSH ključ, bez lozinke
resource "libvirt_cloudinit_disk" "init" {
  for_each = local.vms
  name     = "projekat-${each.key}-init.iso"
  pool     = var.storage_pool
  user_data = templatefile("${path.module}/../../cloud-init/user-data.tftpl", {
    hostname   = each.key
    fqdn       = "${each.key}.${local.plan.zona}"
    admin_user = var.admin_user
    ssh_key    = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })
}

resource "libvirt_domain" "vm" {
  for_each  = local.vms
  name      = "projekat-${each.key}"
  memory    = var.vm_resursi[each.key].memorija_mb
  vcpu      = var.vm_resursi[each.key].vcpu
  autostart = true
  cloudinit = libvirt_cloudinit_disk.init[each.key].id

  disk {
    volume_id = libvirt_volume.disk[each.key].id
  }

  # statička adresa: libvirt upisuje DHCP rezervaciju (MAC -> IP) za ovu VM
  network_interface {
    network_id     = libvirt_network.projekat.id
    hostname       = each.key
    addresses      = [each.value.ip]
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

# DO-6: inventory za Ansible je resurs, generisan iz stanja Terraforma (nikad se ne piše ručno)
resource "local_file" "inventory" {
  filename        = "${path.module}/../../ansible/inventory.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    grupe = {
      for g in distinct([for v in local.vms : v.grupa]) :
      g => { for ime, v in local.vms : ime => libvirt_domain.vm[ime].network_interface[0].addresses[0] if v.grupa == g }
    }
    admin_user = var.admin_user
  })
}
