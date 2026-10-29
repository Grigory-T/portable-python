# Security policy

## Scope and supported release

The latest published release is maintained. Tested target: Windows 11 AMD64,
64-bit Windows PowerShell 5.1, standard-user permissions, and Internet access.
Older local copies do not update themselves. Use a fresh extraction when
upgrading this bootstrap; copy only reviewed application/notebook data.

## Threat model: trusted code, private folder

This tool runs code, it does not decide whether code is trustworthy. Trust the
Windows host/current user, initial ZIP and launcher/TOML, official download
providers, selected packages and application/notebook content. Keep the project
private and run without elevation. If started as administrator, children inherit
that privilege; the launcher neither requests elevation nor removes it.

Controls address corrupt downloads, accidental ambient-interpreter/index/CA
overrides, unsupported install locations, stale launcher-owned config and
concurrent setup. They do not defend against malicious Python/packages, a
compromised OS/current account/upstream provider, or someone who can rewrite
the trusted launcher/state. Reading public source is not itself code execution;
write access and access to authentication files are different threats.

`python -m application` deliberately exposes the trusted project root for imports.
`-E -s` ignores Python overrides/user-site packages, not the venv's `.pth` hooks,
package imports or arbitrary code behavior. Other inherited environment values
(including secrets) can remain readable by code. Infrastructure checks use `-I`
to avoid project-root startup hooks; this does not sandbox installed dependencies.

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
- `SSL_CERT_FILE`/`SSL_CERT_DIR` cannot replace that store: they are cleared in
  the child launcher. Keep Windows and its trusted roots current; this project
  does not manage system certificates. Jupyter also clears inherited `BROWSER`
  commands and requests the normal platform browser (opening is not guaranteed).
  These TLS controls cover launcher downloads, not every HTTP client a user
  application imports; application-specific certificate/proxy policy remains
  the application's responsibility.
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
- Jupyter generates a fresh random authentication token at server startup and
  prints a usable full localhost URL to its console. No token is explicitly
  set in launcher config, command arguments or the journal. Auto-loaded base
  `jupyter*_config.py/json` in the generated config
  directory is refused. Generated config is not a customization interface.

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
Control characters and HTTP URL user-info are stripped/redacted; arbitrary
private strings, alternate path spellings and library-specific messages can
still escape those rules. Redact diagnostics before sharing them.
Jupyter console URLs and runtime connection files contain authentication
material; generated portable-server.json now does too. Never upload those files
or unredacted notebook/console data.

## Supply-chain limitations and maintenance

PyPI is a registry, not an endorsement of all packages. Verify names against
the library author's documentation; pin versions when reproducibility matters.
An online target-generated lock can select different dependencies on another
date. The default graph was tested/reviewed at release time, not guaranteed
free of vulnerabilities forever. User-selected libraries require their own
security/license review.

Live resolution is an explicit design requirement: users choose Python and
libraries on the target without a preparation-machine step. Shipping a locked
default graph would not cover those choices and would need a separate workflow.
The generated lock freezes that installation, not all future fresh installations.
CI additionally checks its installed package versions against OSV; failure or
service unavailability is not called clean. This check is not run by START and
does not certify any later/user-modified graph.

The initial public release used uv **0.13.1**. Current v0.1.4 pins **0.13.6**
and refuses older versions. Versions 0.12.7 through 0.12.17 had a Windows
wheel-extraction vulnerability. See
[GHSA-2cv4-cqwr-gwf7](https://github.com/astral-sh/uv/security/advisories/GHSA-2cv4-cqwr-gwf7).
uv 0.13.4 also removes the compromised emSign CA from its bundled set; see
[GHSA-hq85-5cpj-mr62](https://github.com/astral-sh/uv/security/advisories/GHSA-hq85-5cpj-mr62).
These launchers use Windows system trust, which must independently be updated.
JupyterLab is pinned to **4.6.4**, which fixes the 4.6.3 advisory set; see the
[upstream security page](https://github.com/jupyterlab/jupyterlab/security).
CPython **3.13.18** is the selected security patch release. It adds distrust of
compromised eMudhra intermediate keys in ssl and further security fixes; see the
[official release](https://www.python.org/downloads/release/python-31318/).
uv 0.13.6 includes the updated managed-Python catalog and the earlier uv 0.13.5
certificate-chain rejection fix. The 3.13 line is security-only, not an LTS
promise or a guarantee that an exact patch remains safe indefinitely. Review
future security patches and retest rather than indefinitely freezing these pins.

Before updating pins: inspect upstream advisories/licenses, independently check
published artifact checksums, inspect the uv catalog, test compatible Windows
wheels, run both acceptance suites, and publish source/tag/ZIPs together.
Do not update only a version string while retaining unrelated hashes.
