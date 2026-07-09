provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token # export TF_VAR_pve_api_token=... — never in git
  insecure  = true              # self-signed cert on LAN; switch off once proper certs exist
}
