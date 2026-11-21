output "ip" {
  description = "Adrese VM-ova (ime -> IP), iz stanja libvirta"
  value       = { for ime, vm in libvirt_domain.vm : ime => vm.network_interface[0].addresses[0] }
}

output "dns_server" {
  description = "Adresa autoritativnog DNS servera (koristi terraform/dns i testovi)"
  value       = libvirt_domain.vm["ns1"].network_interface[0].addresses[0]
}

output "mreza" {
  description = "libvirt mreža projekta"
  value       = { ime = libvirt_network.projekat.name, podmreza = local.plan.libvirt_mreza.podmreza }
}

output "inventory" {
  description = "Putanja generisanog Ansible inventoryja"
  value       = abspath(local_file.inventory.filename)
}
