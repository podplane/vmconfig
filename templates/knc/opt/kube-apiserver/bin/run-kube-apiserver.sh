#!/usr/bin/env bash
set -e

log() { printf '[run-kube-apiserver] %s\tts=%s\n' "$*" "$EPOCHREALTIME"; }

log "starting"

# shellcheck source=/dev/null
source /opt/env/kube-apiserver.env
log "loaded /opt/env/kube-apiserver.env"

serviceAccountKeyFile='/opt/pub/service-accounts.pub'
serviceAccountSigningKeyFile='/opt/key/kube-apiserver/service-accounts.key'
clientCaFile='/opt/crt/ca.crt'
etcdCertfile='/opt/crt/kube-apiserver.client.crt'
etcdKeyfile='/opt/key/kube-apiserver/kube-apiserver.client.key'
etcdCafile='/opt/crt/ca.crt'
tlsCertFile='/opt/crt/kube-apiserver.server.crt'
tlsPrivateKeyFile='/opt/key/kube-apiserver/kube-apiserver.server.key'
kubeletClientCertificate='/opt/crt/kube-apiserver.client.crt'
kubeletClientKey='/opt/key/kube-apiserver/kube-apiserver.client.key'
kubeletCertificateAuthority='/opt/crt/ca.crt'
frontProxyClientCertificate='/opt/crt/front-proxy.client.crt'
frontProxyClientKey='/opt/key/kube-apiserver/front-proxy.client.key'
allFiles=(
  "${serviceAccountKeyFile}"
  "${serviceAccountSigningKeyFile}"
  "${clientCaFile}"
  "${etcdCertfile}"
  "${etcdKeyfile}"
  "${etcdCafile}"
  "${tlsCertFile}"
  "${tlsPrivateKeyFile}"
  "${kubeletClientCertificate}"
  "${kubeletClientKey}"
  "${kubeletCertificateAuthority}"
  "${frontProxyClientCertificate}"
  "${frontProxyClientKey}"
)
for file in "${allFiles[@]}"; do
  if [ ! -f "${file}" ]; then
    log "prerequisite failed: file ${file} not found - sleeping for 2 seconds before exiting run script..."
    sleep 2
    exit 1
  fi
done
log "prerequisite files exist"

args=(
  # Set logging verbosity for debugging
  "--v=${KUBE_LOG_LEVEL:-2}"

  #
  # General
  #

  # Service IP CIDR blocks
  "--service-cluster-ip-range=${KUBE_SERVICE_CLUSTER_IP_RANGE}"

  # Prevent goaway (important for single-server clusters)
  '--goaway-chance=0'

  # Hostname presented externally
  "--external-hostname=${KUBE_API_PUBLIC_HOSTNAME}"
  "--secure-port=${KUBE_API_PORT:-6443}"

  #
  # Settings for etcd
  #

  # Disable etcd compaction - netsy handles this
  '--etcd-compaction-interval=0'

  # Disable watch cache, enabled by default
  '--watch-cache=false'

  # Server address for "etcd cluster" (netsy)
  "--etcd-servers=${KUBE_API_ETCD_SERVERS}"

  # Increase default timeout to 5 seconds
  '--etcd-healthcheck-timeout=5s'
  '--etcd-readycheck-timeout=5s'

  #
  # Service Accounts
  #

  "--service-account-issuer=https://${KUBE_API_PUBLIC_HOSTNAME}"
  "--service-account-jwks-uri=https://${KUBE_API_PUBLIC_HOSTNAME}/.well-known/openid-configuration"

  # Keys for verification and signing of Service Accounts
  "--service-account-key-file=${serviceAccountKeyFile}"
  "--service-account-signing-key-file=${serviceAccountSigningKeyFile}"

  #
  # Certs
  #

  # Client certification verification
  "--client-ca-file=${clientCaFile}"

  # Certs for connecting to "etcd cluster" (netsy)
  "--etcd-certfile=${etcdCertfile}"
  "--etcd-keyfile=${etcdKeyfile}"
  "--etcd-cafile=${etcdCafile}"

  # Certs for API server
  "--tls-cert-file=${tlsCertFile}"
  "--tls-private-key-file=${tlsPrivateKeyFile}"

  # Configure TLS version and cipher suites
  '--tls-min-version=VersionTLS13'
  '--tls-cipher-suites=TLS_AES_256_GCM_SHA384'

  # Certs for connecting to kubelets
  "--kubelet-client-certificate=${kubeletClientCertificate}"
  "--kubelet-client-key=${kubeletClientKey}"
  "--kubelet-certificate-authority=${kubeletCertificateAuthority}"

  # Certs and headers for aggregated API servers
  "--proxy-client-cert-file=${frontProxyClientCertificate}"
  "--proxy-client-key-file=${frontProxyClientKey}"
  '--requestheader-allowed-names=front-proxy-client'
  "--requestheader-client-ca-file=${clientCaFile}"
  '--requestheader-extra-headers-prefix=X-Remote-Extra-'
  '--requestheader-group-headers=X-Remote-Group'
  '--requestheader-uid-headers=X-Remote-Uid'
  '--requestheader-username-headers=X-Remote-User'

  #
  # Kubelet connection settings - use IPs instead of Hostnames to connect
  #

  "--kubelet-preferred-address-types=InternalIP,InternalDNS"

  #
  # User authentication
  #

  # Prevent anonymous API access
  '--anonymous-auth=false'

  #
  # OIDC
  # @see: https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-flags
  # REQUIRED: URL of the provider that allows the API server to discover
  # public signing keys.
  #
  "--oidc-issuer-url=${OIDC_ISSUER}"

  #
  # REQUIRED: A client id that all tokens must be issued for.
  # Note that we use Cluster ID meaning users are required to use a
  # different OIDC token per cluster.
  #
  "--oidc-client-id=${CLUSTER_ID}"

  #
  # JWT claim to use as the user name. By default sub, which is expected
  # to be a unique identifier of the end user.
  # Note that we put the user ID in the sub, but it is more useful
  # for audit purposes to show the users' validated email address.
  #
  '--oidc-username-claim=email'

  #
  # Prefix prepended to username claims to prevent clashes with existing
  # names. Defaults to ( Issuer URL )#
  # Note: we use the email as the username, so we don't want to prefix it.
  #
  '--oidc-username-prefix='

  #
  # JWT claim to use as the user's group
  # Note that we put a string array of group slugs into the OIDC token,
  # and these group slugs are unique within the account.
  #
  '--oidc-groups-claim=groups'

  #
  # Prefix prepended to group claims to prevent clashes with existing
  # names. Also assists with writing policies/CEL matching.
  #
  '--oidc-groups-prefix='

  #
  # A key=value pair that describes a required claim in the ID Token. If
  # set, the claim is verified to be present in the ID Token with a
  # matching value. Repeat this flag to specify multiple claims.
  # Note: this is currently unused.
  # '--oidc-required-claim='
  # The signing algorithms accepted. Default is "RS256".
  #
  "--oidc-signing-algs=${OIDC_SIGNING_ALGS}"

  #
  # Authorization Mode defaults to AllowAll
  # Node permits nodes, RBAC is used for users
  #
  '--authorization-mode=Node,RBAC'

  # Adminission Plugins to enable (in addition to default ones)
  '--enable-admission-plugins=NodeRestriction,NamespaceExists,OwnerReferencesPermissionEnforcement'

  # Note: required for Cilium. Use Pod Security Policy to restrict.
  '--allow-privileged=true'
)

# check if a custom CA file is configured and exists and append the oidc-ca-file
# argument if it does. this is mainly used for CLI local mode.
if [ -n "$OIDC_CA_FILE" ]; then
  if [ -f "$OIDC_CA_FILE" ]; then
      args+=("--oidc-ca-file=$OIDC_CA_FILE")
  fi
fi

log "exec kube-apiserver"
exec /usr/bin/kube-apiserver "${args[@]}"
