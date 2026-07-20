#!/usr/bin/env bash
# Build the Ubuntu 24.04 cloud-init template (VM 9000) that Terraform clones.
# Run ON the Proxmox host. Storage assumed: local-zfs. Bridge: vmbr0.
set -euo pipefail

VMID=9000
NAME=ubuntu-2404-cloudinit
STORAGE=local-zfs
IMG=noble-server-cloudimg-amd64.img
URL=https://cloud-images.ubuntu.com/noble/current/${IMG}

cd /var/lib/vz/template
[ -f "$IMG" ] || wget -O "$IMG" "$URL"

apt-get install -y libguestfs-tools
virt-customize -a "$IMG" \
  --install qemu-guest-agent \
  --run-command 'systemctl enable qemu-guest-agent'

qm create "$VMID" --name "$NAME" --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --machine q35 --ostype l26
qm set "$VMID" --scsihw virtio-scsi-single \
  --scsi0 ${STORAGE}:0,import-from=/var/lib/vz/template/${IMG}
qm set "$VMID" --ide2 ${STORAGE}:cloudinit
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --agent enabled=1
qm template "$VMID"
echo "Template $VMID ($NAME) ready."
