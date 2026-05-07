#!/usr/bin/env bash
set -e
# shellcheck source=/dev/null
source /opt/env/zot.env
if [ "$REGISTRY_BUCKET" == "" ]
then
    echo "REGISTRY_BUCKET is not set. Exiting..."
    exit 1
fi
if [ ! -f /opt/crt/registry.server.crt ]
then
    echo "registry.server.crt is not found. Exiting..."
    exit 1
fi
if [ ! -f /opt/key/registry/registry.server.key ]
then
    echo "registry.server.key is not found. Exiting..."
    exit 1
fi
if [ ! -f /opt/zot/etc/zot.yml ]
then
    echo "zot.yml is not found. Exiting..."
    exit 1
fi
args=(
    "serve"
    "/opt/zot/etc/zot.yml"
)
if [ "$REGISTRY_ASSUME_ROLE" != "" ]; then
    export AWS_SDK_LOAD_CONFIG=1
    export AWS_ROLE_ARN="${REGISTRY_ASSUME_ROLE}"
    export AWS_ROLE_SESSION_NAME="${INSTANCE_ID}-zot"
elif [ "${REGISTRY_ACCESS_KEY_ID:-}" != "" ] || [ "${REGISTRY_SECRET_ACCESS_KEY:-}" != "" ]; then
    export AWS_ACCESS_KEY_ID="${REGISTRY_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${REGISTRY_SECRET_ACCESS_KEY}"
fi
exec /usr/bin/zot "${args[@]}"
