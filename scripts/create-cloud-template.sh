#!/usr/bin/env bash
# Build the Ubuntu 24.04 cloud-init template (VM 9000) that Terraform clones.
# Run ON the Proxmox host. Idempotent-ish: destroy 9000 first to rebuild.
# Storage assumed: local-zfs. Bridge: vmbr0.
set -euo pipefail

VMID=9000
NAME=ubuntu-2404-cloudinit
STORAGE=local-zfs
IMG=noble-server-cloudimg-amd64.img
URL=https://cloud-images.ubuntu.com/noble/current/${IMG}

cd /var/lib/vz/template

# 1. Download the cloud image (skip if present)
[ -f "$IMG" ] || wget -O "$IMG" "$URL"

# 2. Bake in the qemu guest agent so Proxmox sees the VM's IP
apt-get install -y libguestfs-tools
virt-customize -a "$IMG" \
  --install qemu-guest-agent \
  --run-command 'systemctl enable qemu-guest-agent'

# 3. Create the VM shell
qm create "$VMID" --name "$NAME" --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --machine q35 --ostype l26

# 4. Import the disk straight onto ZFS
qm set "$VMID" --scsihw virtio-scsi-single \
  --scsi0 ${STORAGE}:0,import-from=/var/lib/vz/template/${IMG}

# 5. Cloud-init drive + boot + serial console + agent
qm set "$VMID" --ide2 ${STORAGE}:cloudinit
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --agent enabled=1

# 6. Seal it as a template
qm template "$VMID"
echo "Template $VMID ($NAME) ready. Terraform can now clone it."
