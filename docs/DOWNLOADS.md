# Downloads and provenance

The target downloads executable/package artifacts; the release ZIPs contain
only this project's text source, examples and license notices.

## uv 0.13.1

Automatic bootstrap URL:

```text
https://releases.astral.sh/github/uv/releases/download/0.13.1/uv-x86_64-pc-windows-msvc.zip
```

Pinned archive SHA-256:

```text
3b2661a463a5baea7f5076ea2b25ab71d77f36a6c0d809e5350651792f80a672
```

Pinned extracted `uv.exe` SHA-256:

```text
4075a09490327d2bedfacc807fa48252fb93647c5bd7ef28f00e579160ea3fb5
```

Review references, not extra automatic downloads:

- [Official release](https://github.com/astral-sh/uv/releases/tag/0.13.1)
- [Official checksum](https://releases.astral.sh/github/uv/releases/download/0.13.1/uv-x86_64-pc-windows-msvc.zip.sha256)

The release's GitHub asset digest and downloaded archive checksum were compared;
the executable hash was independently computed from the verified ZIP. The hashes
are in each TOML and the release builder. Runtime does not trust a newly
downloaded checksum beside an arbitrary archive.

## CPython 3.13.16

The default exact Windows x86-64 distribution in the pinned uv catalog is:

```text
https://releases.astral.sh/github/python-build-standalone/releases/download/20261013/cpython-3.13.16%2B20261013-x86_64-pc-windows-msvc-install_only_stripped.tar.gz
```

uv supplies its embedded distribution checksum and verifies the download. The
launcher requires a single exact Windows AMD64 record and an HTTPS
`releases.astral.sh` origin. It prints that URL before installation. Runtime
and venv stay under the project; no global command/registry entry is installed.

References: [Python release](https://www.python.org/downloads/release/python-31316/),
[build provider](https://github.com/astral-sh/python-build-standalone),
[uv managed Python](https://docs.astral.sh/uv/guides/install-python/).

Changing `requires-python = "==..."` selects a different catalog record, printed
at setup. That version must exist and be compatible with the requested wheels.
Prefer current supported security patches, not an old patch merely because it
still exists in the download catalog.

## Package metadata and wheels

```text
https://pypi.org/simple
https://pypi.org/simple/<normalized-package-name>/
https://files.pythonhosted.org/packages/...
```

The Python application template has no third-party libraries by default. The
notebook template pins JupyterLab 4.6.4 and ipykernel 7.4.0 and resolves their
dependencies. References: [JupyterLab](https://pypi.org/project/jupyterlab/4.6.4/),
[ipykernel](https://pypi.org/project/ipykernel/7.4.0/).

`uv lock` obtains metadata and writes exact versions, conditions, artifact URLs
and hashes to the target's `uv.lock`. The launcher checks approved HTTPS origins
before `uv sync --locked --no-build`; uv verifies wheel hashes. No persistent
requirements.lock/export step is needed. Generated lock entries can include
other-platform wheels/source archive metadata; source builds are not allowed.

This is not a complete network firewall: official services can redirect and
dependency resolution processes publisher metadata. Source-origin checks and
hashes do not make an arbitrary package trustworthy. Review user dependencies.
The exact resolved graph is target/date-specific, not a permanently audited
graph shipped inside the ZIP.

## Network clients and privacy

PowerShell HTTPS bootstrap uses the current user's selected proxy credentials;
BITS retries AutoDetect/SystemDefault with Negotiate if needed. Python/package
downloads instead use uv's client. Standard proxy variables may apply; automatic
Windows proxy authentication is not guaranteed in uv. TLS verification remains
on, using Windows trust. No origin credentials, fixed IPs, corporate endpoints,
or mirror overrides are embedded.

DNS/CDN addresses and HTTPS redirects may change. Depending on upstream routing,
GitHub release infrastructure can include `github.com` and
`release-assets.githubusercontent.com`. A browser download succeeding does not
prove that the launcher's download client works through the same proxy policy.

Unchanged application starts perform no infrastructure download. Jupyter's
extension installer is read-only and built-in news/update polling is disabled.
Notebook/application code and user-installed third-party packages can still
make their own requests. The launcher is not a network sandbox.
