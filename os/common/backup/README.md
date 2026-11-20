# backup

Shared backup observability used by backup and restore-test scripts across stacks.

## What is here

| File | Purpose |
|---|---|
| `backup-receipt.sh` | Sourced JSONL writer for backup and restore-test outcomes. |
| `backup-encrypt.sh` | Encrypts an archive to the configured OpenPGP public key before it is written to shared storage. |

## How to use it

Source `backup-receipt.sh` and call `backup_receipt_record` once after each backup or restore-test run, including failed
runs. Pass the archive class, recovery group, artifact metadata, result and elapsed time. Restore-test records also require
the restored item and a concise outcome.

Backup records may include a concise `--warning` when the run completes with a non-fatal limitation.
Encrypted backup records may set `--encrypted true`; this adds the boolean `encrypted` field to the receipt.

Source `backup-encrypt.sh` and call `backup_encryption_check` before a backup or
`backup_encrypt_archive INPUT OUTPUT` to encrypt it. The helper requires GnuPG
and an armored public key at `/etc/andrusone/backup-recipient.asc`; set
`BACKUP_GPG_RECIPIENT_FILE` in the stack's backup environment file to override
that path. The file must contain only the recipient public key. The private key
is kept offline and is never needed on the host. Encryption failures are fatal
to the backup; callers must not publish the plaintext archive.

The helper appends to `/var/lib/backup-receipts/receipts.jsonl` when system state is available, otherwise to the user's
state directory. `BACKUP_RECEIPTS_LOG` overrides the path for tests or an operator configuration. Receipt failures warn
on stderr but never change the calling script's exit status.

The schema and field meanings are in [`spec-backup-receipt.md`](../../../../docs/standards/spec-backup-receipt.md).
