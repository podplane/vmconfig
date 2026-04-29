# Podplane VM Configuration

Podplane `vmconfig` is a minimal configuration system for the [Podplane](https://podplane.dev) Kubernetes distribution & PaaS, designed for Debian-based Linux VMs, written in Bash.

## How It Works

The published packages vary the VM configuration based on the desired VM "kind":

- `knd` creates a Kubernetes Data Plane / Worker node, which runs kubelet, containerd, and supporting services.

- `knc` creates a Kubernetes Control Plane node, which is essentially a base of `knd` + adds [netsy](https://netsy.dev) (as an etcd alternative), kube-apiserver, kube-scheduler, kube-controller-manager, etc.

The VM cloud-init user-data script is responsible for downloading, verifying, and decompressing all dependencies required for its nominated VM kind, and invoking the `vmconfig` package entrypoint.

The full list of dependencies per VM kind is published in a `dependencies.json` file.

## Learn More

Learn more about Podplane at the official project website: [podplane.dev](https://podplane.dev)

For more information about `vmconfig` specifically, please read the documentation at: [podplane.dev/docs/vmconfig](https://podplane.dev/docs/vmconfig)

## License

Podplane is licensed under the Apache License, Version 2.0.
Copyright 2026 Nadrama Pty Ltd.

See the [LICENSE](./LICENSE) file for details.
