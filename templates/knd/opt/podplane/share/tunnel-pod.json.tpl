{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "podplane-tunnel", "namespace": "kube-system"},
  "spec": {
    "hostNetwork": true,
    "dnsPolicy": "Default",
    "automountServiceAccountToken": false,
    "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
      "name": "tunnel",
      "image": %s,
      "imagePullPolicy": "IfNotPresent",
      "args": [%s],
      "securityContext": {
        "runAsNonRoot": true,
        "readOnlyRootFilesystem": true,
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]}
      },
      "volumeMounts": [%s]
    }],
    "volumes": [%s]
  }
}
