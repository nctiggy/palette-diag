# palette-diag

One-shot diagnostic collector for a **Spectro Cloud Palette Management Appliance**
(the self-hosted control plane installed from the ISO).

It gathers cluster state, Palette control-plane internals, the internal pack
registry, certificates, and host-level data from every node via short-lived
privileged pods — then packages everything into a single `.tgz` and optionally
uploads it.

## Usage

```bash
export KUBECONFIG=/path/to/appliance.kubeconfig
curl -fsSL https://raw.githubusercontent.com/nctiggy/palette-diag/main/collect-pma.sh \
  | bash -s -- --upload https://your-upload-host
```

Omit `--upload` to build the bundle only; it is always written to `/tmp`.

| Flag | Effect |
| --- | --- |
| `--upload URL` | upload endpoint |
| `--no-upload` | build only |
| `--no-nodes` | skip the privileged host-collection phase |
| `--image REF` | force the helper-pod image |
| `--kubeconfig` / `--context` | override the ambient context |

## Air-gapped by design

An appliance has no egress, so a helper pod cannot pull `ubuntu` or `busybox`.
The script reuses an image already cached on the node and probes what it can
actually do before trusting it: `nsenter` → `chroot` → direct `/host` file reads
using shell builtins. Palette nodes mix full images with distroless ones that
have a shell but no `nsenter`, no `chroot` and no coreutils, so the third tier
matters.

## Safety

- Read-only; nothing on the appliance is modified.
- Secret **values** are never collected — names, types and ages only. TLS secrets
  contribute subject/issuer/expiry, never the key.
- A redaction pass rewrites `password` / `token` / `apikey` / `access_key` /
  `bearer` / `client-key-data` values to `<REDACTED>` and strips PEM private-key
  bodies, because ISO-installed appliances keep the node password and
  registration token in `/oem` in clear text.
- Every helper pod is force-deleted on exit, including on Ctrl-C.

The bundle is a plain `.tgz` — review it before forwarding if your environment
requires that.
