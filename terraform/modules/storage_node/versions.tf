terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.110.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}
