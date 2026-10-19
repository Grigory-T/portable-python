# Initial public release review

Reviewed: 2026-10-19. This is a limited engineering review, not a security
certification or comprehensive legal audit.

## Changes before public release

- Selected uv 0.13.1 and verified its official GitHub asset digest, upstream
  checksum and extracted executable SHA-256. Earlier uv 0.12.7 is affected by
  [a Windows extraction advisory](https://github.com/astral-sh/uv/security/advisories/GHSA-2cv4-cqwr-gwf7).
- Selected maintained CPython 3.13.16 from the pinned uv catalog, not the
  earlier development patch.
- Selected JupyterLab 4.6.4 and ipykernel 7.4.0. The JupyterLab security page
  records fixes affecting 4.6.3, including clipboard XSS and extension-manager
  argument injection. [Upstream advisories](https://github.com/jupyterlab/jupyterlab/security).
- Kept the two source-only ZIPs small and independent. Added MIT and third-party
  notices, explicit platform checks, system-path PowerShell invocation, and a
  minimum fixed uv version. No remote shell installer is downloaded/executed.
- Disabled Jupyter's independent extension installer, news and update polling.
  Server remains localhost/token-authenticated with only its local venv kernel.

## Checks performed

- Explicit file allowlist; no existing repository history, generated runtime,
  personal configuration, private endpoints, real usernames, or saved notebook
  output in the public source/archives. Commit metadata is project-neutral.
- Deterministic ZIP rebuild, SHA-256, Python/TOML/notebook/PowerShell syntax,
  MIT inclusion, and artifact/source correspondence.
- Fresh Windows PowerShell 5.1 setup and normal/repeated application run,
  actual START.bat, nested imports, empty defaults, custom library range,
  original application exit code, and changed-configuration refusal.
- Fresh/reused notebook setup, declared package addition/removal, malformed
  Jupyter-group recovery, Unicode/nested notebooks, local kernelspec, actual
  WebSocket execution, loopback listener, concurrent-start refusal, read-only
  extension manager, clean shutdown and no token in the infrastructure journal.
- Official PyPI metadata check of the 90 resolved Windows notebook packages:
  zero active listed advisories at review time. Metadata can be incomplete and
  changes over time. This result does not cover arbitrary user-added packages.
- Basic upstream/license metadata review: original source remains MIT;
  downloaded binaries/packages keep their own terms. Some package metadata has
  missing/incomplete license fields; do not treat it as a full redistribution
  clearance for a prepared runtime/environment.

Automated server acceptance deliberately used no browser. Normal START requests
automatic browser opening; verify that interaction on the user's own desktop.
See [testing](TESTING.md), [download provenance](DOWNLOADS.md), and
[security limitations](../SECURITY.md) for the precise scope.
