# Security policy

## Scope and supported release

The latest published release is maintained. Tested target: Windows 11 AMD64,
64-bit Windows PowerShell 5.1, standard-user permissions, and Internet access.
Older local copies do not update themselves. Use a fresh extraction when
upgrading this bootstrap; copy only reviewed application/notebook data.

Please report vulnerabilities privately through this repository's **Security
advisories / Report a vulnerability** feature. Do not post tokens, usernames,
local paths, private URLs, notebook data, or credentials in public issues.
For ordinary bugs, provide a minimal example and redacted diagnostics.

## Trust boundaries

- Review the ZIP source and compare its SHA-256 with the release notes before
  execution when authenticity matters. Release-note hashes detect corruption;
  they are not independent signatures or protection from a compromised account.
- The reviewed local launcher and TOML bootstrap hashes are trusted inputs.
  Do not run from an untrusted/shared/writable directory. A local attacker who
  can replace the launcher can replace its trust policy too.
- Hash verification checks bytes, not whether upstream code is benign.
  Packages and notebooks can execute arbitrary code with your permissions.
- A venv, a localhost server, and the notebook browser root are not sandboxes.
  Do not disable token authentication or expose this server to the network.
- The ready marker is a configuration fingerprint, not a full tamper audit of
  installed files. Arbitrary changes to the generated environment are outside
  the supported reproducibility contract.

## Download and execution controls

- uv archive/executable SHA-256 pins are checked before execution; CPython is
  selected from that pinned uv's embedded catalog and checksum-verified by uv.
- Package resolution uses official PyPI. Before installation, lock origins must
  be HTTPS `pypi.org` or `files.pythonhosted.org`; uv checks artifact hashes.
- Source builds are disabled during lock and sync. Direct URLs, custom indexes,
  build metadata and extra dependency groups are rejected by the profile policy.
- Inherited `UV_*` overrides are cleared; only local runtime/cache paths are set.
  Standard proxy variables remain supported. TLS checks stay enabled and use
  the Windows certificate store. There is no insecure-host fallback.
- Windows integrated credentials are used only for the selected proxy during
  the uv bootstrap. No username/password is embedded or saved. uv's own client
  does not guarantee PAC/Negotiate support; fail rather than weaken trust.
- Files are first downloaded to local partial files. Temporary extraction
  content is removed after verification. System Python is not used/registered.
- The target must be local/fixed and not a junction or network path. A workspace
  lock prevents concurrent installer/server/application use. This is accidental-
  misuse protection, not protection against an administrator or local attacker.
- Jupyter binds to loopback, keeps token authentication, exposes only the local
  Python kernel, and uses a read-only extension manager. News/update polling is
  disabled; package changes remain in TOML/uv.

START invokes the local reviewed PowerShell file with a process-scoped
ExecutionPolicy Bypass for double-click convenience. Execution policy is not a
code-authenticity mechanism. This does not change persistent system policy or
override organization-enforced application controls. Do not disable endpoint
security to make this tool run.

## Privacy and diagnostics

The project implements no telemetry. Internet setup reveals ordinary package/
runtime requests to upstream services. User application code and third-party
software may make their own network requests. See [DOWNLOADS](docs/DOWNLOADS.md).

Local JSONL journals contain setup steps, durations, versions and exit status;
known account/project paths are substituted. This is not a universal secret
redactor. Application output is displayed, not journaled by the launcher.
Jupyter console URLs and runtime connection files contain authentication
material. Never upload those files or unredacted notebook/console data.

## Supply-chain limitations and maintenance

PyPI is a registry, not an endorsement of all packages. Verify names against
the library author's documentation; pin versions when reproducibility matters.
An online target-generated lock can select different dependencies on another
date. The default graph was tested/reviewed at release time, not guaranteed
free of vulnerabilities forever. User-selected libraries require their own
security/license review.

The first public release upgrades the earlier development uv pin to **0.13.1**.
Versions 0.12.7 through 0.12.17 have a Windows wheel-extraction vulnerability;
the bootstrap refuses uv versions below 0.12.18. See
[GHSA-2cv4-cqwr-gwf7](https://github.com/astral-sh/uv/security/advisories/GHSA-2cv4-cqwr-gwf7).
JupyterLab is pinned to **4.6.4**, which fixes the 4.6.3 advisory set; see the
[upstream security page](https://github.com/jupyterlab/jupyterlab/security).
CPython **3.13.16** is the selected maintained security patch release.

Before updating pins: inspect upstream advisories/licenses, independently check
published artifact checksums, inspect the uv catalog, test compatible Windows
wheels, run both acceptance suites, and publish source/tag/ZIPs together.
Do not update only a version string while retaining unrelated hashes.
