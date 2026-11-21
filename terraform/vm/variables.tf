variable "libvirt_uri" {
  description = "Adresa libvirt daemona"
  type        = string
  default     = "qemu:///system"
}

variable "storage_pool" {
  description = "libvirt storage pool za diskove (00-setup.sh iz repozitorija predmeta pravi 'default')"
  type        = string
  default     = "default"
}

variable "base_image_url" {
  description = "Bazna cloud slika (DO-4)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "admin_user" {
  description = "Korisnik za upravljanje koji pravi cloud-init (AO-4)"
  type        = string
  default     = "ruo"
}

variable "ssh_public_key_path" {
  description = "Javni SSH ključ administratora; privatni ključ nikad ne napušta računar"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vm_resursi" {
  description = "Resursi po VM-u; ključevi moraju odgovarati mašinama iz plan-adresa.yaml"
  type = map(object({
    memorija_mb = number
    vcpu        = number
    disk_gb     = number
  }))
  default = {
    ns1  = { memorija_mb = 512, vcpu = 1, disk_gb = 8 }
    app1 = { memorija_mb = 2048, vcpu = 2, disk_gb = 15 }
  }
}
