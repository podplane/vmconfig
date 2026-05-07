#!/usr/bin/env bash
set -euo pipefail

# This script validates a delivered mutable.env file, merges it into the
# VM-local /opt/podplane/etc/mutable.env, and optionally deletes the source
# file. The destination mutable.env is the allowlist: bootstrap.sh seeds every
# key that this VM kind is allowed to mutate later.

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <path_to_source_env_file> <path_to_dest_env_file> (<delete_source_env_file=false>)"
  exit 1
fi

SOURCE_ENV_FILE="$1"
DEST_ENV_FILE="$2"
DELETE_SOURCE_ENV_FILE=false
if [ "${3:-}" = "true" ] || [ "${3:-}" = "1" ]; then
  DELETE_SOURCE_ENV_FILE=true
fi

if [ ! -f "$SOURCE_ENV_FILE" ]; then
  echo "Source file not found: $SOURCE_ENV_FILE"
  exit 1
fi

if [ ! -f "$DEST_ENV_FILE" ]; then
  echo "Destination mutable env file not found: $DEST_ENV_FILE"
  exit 1
fi

validate_env_value() {
  local key="$1"
  local value="$2"

  [ -z "$value" ] && return 0

  if [[ ! "$value" =~ ^[\-\ a-zA-Z0-9\.\/_:+=#@,]+$ ]]; then
    echo "Invalid characters in value for key '$key': $value" >&2
    echo "Only alphanumeric characters, spaces, and -./_:+=#@, are allowed" >&2
    exit 1
  fi

  if [ "${#value}" -gt 4096 ]; then
    echo "Value for key '$key' exceeds maximum length (4096 characters)" >&2
    exit 1
  fi
}

load_env_file_to_map() {
  local file="$1"
  local -n map_ref="$2"
  local key value

  while IFS='=' read -r key value; do
    [[ $key =~ ^#.*$ || -z $key ]] && continue

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "Invalid key format: $key (must be alphanumeric with underscores)" >&2
      exit 1
    fi

    value="${value:-}"
    if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value#?}"
      value="${value%?}"
    fi

    validate_env_value "$key" "$value"
    # shellcheck disable=SC2034 # Assignment through nameref mutates caller's map.
    map_ref["$key"]="$value"
  done < <(sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' "$file")
}

quote_env_value() {
  local value="${1:-}"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

declare -A ENV_MAP
echo -n "Loading existing mutable env file ${DEST_ENV_FILE}... "
load_env_file_to_map "$DEST_ENV_FILE" ENV_MAP
echo "Done."

declare -A NEW_ENV_MAP
echo -n "Loading new env file ${SOURCE_ENV_FILE}... "
load_env_file_to_map "$SOURCE_ENV_FILE" NEW_ENV_MAP
echo "Done."

for key in "${!NEW_ENV_MAP[@]}"; do
  if [[ ! -v "ENV_MAP[$key]" ]]; then
    echo "Key '$key' is not present in ${DEST_ENV_FILE} and cannot be updated. Exiting..."
    exit 1
  fi
done

for key in "${!NEW_ENV_MAP[@]}"; do
  ENV_MAP["$key"]="${NEW_ENV_MAP[$key]}"
done

echo -n "Ensuring correct permissions for ${DEST_ENV_FILE}... "
touch "$DEST_ENV_FILE"
chmod 0600 "$DEST_ENV_FILE"
if [ "$(id -u)" = "0" ]; then
  chown root:root "$DEST_ENV_FILE"
fi
echo "Done."

echo -n "Writing merged env vars to ${DEST_ENV_FILE}... "
{
  for key in "${!ENV_MAP[@]}"; do
    printf '%s=%s\n' "$key" "$(quote_env_value "${ENV_MAP[$key]}")"
  done | sort
} > "$DEST_ENV_FILE"
echo "Done."

if [ -x /opt/podplane/lib/configure/hosts.sh ]; then
  echo -n "Refreshing managed hosts entries... "
  /opt/podplane/lib/configure/hosts.sh
  echo "Done."
fi

if [ "$DELETE_SOURCE_ENV_FILE" = true ]; then
  echo -n "Deleting source env file: $SOURCE_ENV_FILE... "
  rm -f "$SOURCE_ENV_FILE"
  echo "Done."
fi

echo "/opt/podplane/bin/update-mutable-env.sh completed successfully."
