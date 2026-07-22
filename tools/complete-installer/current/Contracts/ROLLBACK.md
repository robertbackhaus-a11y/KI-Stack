# Backup and rollback contract

Only files changed by the active complete-installer transaction are backed up and restored. Existing compliant components are skipped and never added to rollback scope. Kernel module changes use the existing module rollback contracts. OpenWebUI Agent and Image Pack backups are stored by their public installers and restored with the same in-memory API token. Production Recovery 1.7.0-r7 remains a manual repair source and is never overlaid automatically on a healthy newer installation.

Resume data contains component IDs, statuses, hashes and non-secret paths only. It never contains credentials or `SecureString` values.
