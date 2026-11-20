# shellcheck shell=bash
# -----------------------------------------------------------------------------
# backup-encrypt.sh
#
# Sourced helper for encrypting backup archives to an OpenPGP recipient key.
# -----------------------------------------------------------------------------

[[ -n "${BACKUP_ENCRYPT_LOADED:-}" ]] && return 0
BACKUP_ENCRYPT_LOADED=1
# shellcheck disable=SC2034
BACKUP_ENCRYPT_LIB_VERSION="1.0.0"

BACKUP_GPG_RECIPIENT_FILE="${BACKUP_GPG_RECIPIENT_FILE:-/etc/andrusone/backup-recipient.asc}"

backup_encryption_check() {
  if ! command -v gpg >/dev/null 2>&1; then
    printf 'backup-encrypt: required command is unavailable: gpg\n' >&2
    return 1
  fi
  if [[ ! -f "$BACKUP_GPG_RECIPIENT_FILE" || -L "$BACKUP_GPG_RECIPIENT_FILE" ||
    ! -r "$BACKUP_GPG_RECIPIENT_FILE" ]]; then
    printf 'backup-encrypt: recipient public key file is unavailable\n' >&2
    return 1
  fi
  if ! grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$BACKUP_GPG_RECIPIENT_FILE" ||
    grep -Eq '^-----BEGIN PGP (PRIVATE|SECRET) KEY BLOCK-----$' "$BACKUP_GPG_RECIPIENT_FILE"; then
    printf 'backup-encrypt: recipient file must contain only an armored public key\n' >&2
    return 1
  fi
}

backup_encrypt_archive() {
  if (($# != 2)); then
    printf 'backup-encrypt: expected input and output paths\n' >&2
    return 1
  fi
  local input="$1" output="$2"
  if [[ ! -f "$input" || -L "$input" ]]; then
    printf 'backup-encrypt: input archive is unavailable\n' >&2
    return 1
  fi
  if [[ "$input" -ef "$output" ]]; then
    printf 'backup-encrypt: input and output paths must differ\n' >&2
    return 1
  fi
  if [[ -e "$output" && ! -f "$output" || -L "$output" ]]; then
    printf 'backup-encrypt: output path is not a regular file\n' >&2
    return 1
  fi
  backup_encryption_check || return 1
  if ! gpg --batch --yes --no-tty \
    --output "$output" \
    --encrypt --recipient-file "$BACKUP_GPG_RECIPIENT_FILE" "$input"; then
    printf 'backup-encrypt: archive encryption failed\n' >&2
    return 1
  fi
  if [[ ! -s "$output" ]]; then
    printf 'backup-encrypt: encrypted archive is empty\n' >&2
    return 1
  fi
}
