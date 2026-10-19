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
.\tests\application.ps1 -Zip .\dist\portable-python-one-launcher-0.1.0-windows-x86_64.zip
.\tests\jupyterlab.ps1 -Zip .\dist\portable-python-jupyterlab-0.1.0-windows-x86_64.zip
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

Release verification also includes a manual privacy scan, official artifact
checksum comparison, upstream advisory review, and limited license review.
Passing tests is not a guarantee that every user package or notebook is safe.
