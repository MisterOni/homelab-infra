#!/usr/bin/env bash
# Runnable documentation: ZFS pools on the K8 Plus. Review disk IDs first!
# ls -l /dev/disk/by-id/ to find your two HDDs — NEVER use /dev/sdX names.
set -euo pipefail
MEDIA_DISK="/dev/disk/by-id/CHANGE-ME-hdd1"
BACKUP_DISK="/dev/disk/by-id/CHANGE-ME-hdd2"

# Single-disk pools ON PURPOSE (see ADR: media is re-downloadable, backups are the redundancy)
zpool create -o ashift=12 media "$MEDIA_DISK"
zpool create -o ashift=12 backup "$BACKUP_DISK"

zfs create -o recordsize=1M media/movies      # large sequential files
zfs create -o recordsize=1M media/tv
zfs create media/downloads
zfs create backup/pbs                          # Proxmox Backup Server datastore
zfs create backup/gitlab

zfs set compression=lz4 media backup
zpool status
