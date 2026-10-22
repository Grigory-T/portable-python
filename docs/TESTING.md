# Build and test

## Offline source build

Build machine: Python 3.11+ and PowerShell (`pwsh` or `powershell.exe`).

```text
python scripts/build.py
```

The builder makes exactly two deterministic ZIPs, including MIT and third-party
notices. It uses an explicit file allowlist; no venv, runtime, cache, lock, saved
notebook output, hidden user configuration or existing git history is included.
It does not download or execute uv/CPython. SHA-256 is printed for release notes.

## Windows acceptance

Machine: a Windows 11 AMD64 test machine with Internet access. These tests run
code, download official binaries/wheels, create local temporary folders, and
retain their generated test folders for inspection. No production data is used.

After building, from the repository root in PowerShell:

```powershell
.\tests\application.ps1 -Zip .\dist\portable-python-one-launcher-0.1.2-windows-x86_64.zip -Audit
.\tests\jupyterlab.ps1 -Zip .\dist\portable-python-jupyterlab-0.1.2-windows-x86_64.zip -Audit
```

Application checks: fresh setup/run, empty-library default, Unicode path,
unchanged start, actual START.bat, nested absolute/relative imports, original
app exit code, configuration-drift refusal, neutral journal, and a fresh
custom PyPI version-range requirement.

Notebook checks: fresh/reused setup, declared package add/remove, wrong-group
validation/recovery, local-only kernelspec, loopback listener, concurrent-start
rejection, and actual kernel execution through the server WebSocket API from
a copied nested notebook. It checks the venv prefix, Python, user-site setting,
working directory, unchanged notebook bytes, absence of a token in the journal,
and clean API shutdown. Automated server tests use `-NoBrowser`; confirm normal
browser opening interactively on a real user desktop too.

CI uses read-only repository permissions and a commit-pinned checkout action.
It runs offline source validation/build and both online Windows acceptance
tests. No credentials are needed for artifact/package downloads. Tests deliberately
set an invalid inherited uv index to verify the launcher clears that override.

Additional regressions cover literal square brackets in paths, inherited
SSL_CERT_FILE/SSL_CERT_DIR/BROWSER overrides, project-root startup-hook isolation
during application infrastructure checks, stale Jupyter config refusal, fresh
session tokens, and rejection of unauthenticated kernel access.

Jupyter regression tests add openpyxl then Polars in the saved TOML, remove a
Polars distribution to verify repair despite an unchanged ready marker, and
run real Polars computation through a notebook kernel. They assert the full
usable URL (including the actual runtime token) appears in console output,
without copying the token to CI messages or the launcher journal.

Shutdown waits up to 90 seconds for the owned launcher and checks that its
listening port closed. Failures print redacted server-output tails and clean
only the test-created process tree. Forced cleanup never converts failure into
success. The cause of earlier CI-only 30-second failures is not assumed fixed
merely by increasing the timeout; repeated green Windows CI is required.

`-Audit` additionally runs `scripts/audit.py` using the tested project venv.
It POSTs installed public PyPI package names/versions to
`https://api.osv.dev/v1/querybatch` and fails on known advisories or unavailable/
invalid responses. This developer/CI helper is not included in the user ZIPs,
adds no user-runtime downloads and does not run on START. Omitting -Audit skips
only that network check, not acceptance. OSV is point-in-time advisory metadata,
not a code audit or proof that a later target resolution is safe.

Release verification also includes a manual privacy scan, official artifact
checksum comparison, upstream advisory review, and limited license review.
Passing tests is not a guarantee that every user package or notebook is safe.
