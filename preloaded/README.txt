PORTABLE PYTHON PRELOADED — Windows 11 x86-64

Both machines need 64-bit Windows PowerShell 5.1, a private writable
folder on a local fixed drive and permission to run the bundled code.
No admin install, global PATH changes, system Python, pip or compilers.

1. ONLINE SETUP MACHINE

Unpack the small starter ZIP into a fresh local folder. Put your trusted
Python package in application/ (entry point: application/__main__.py).
Nested modules and relative imports work normally. Run context is the bundle
root with "python -m application"; use UTF-8 for Python source and make data
paths relative to __file__ or the bundle root, not to the setup machine.

Edit pyproject.toml before SETUP. Exact CPython and uv pins default to
3.13.18 and 0.13.6. Choose a normal Windows AMD64 CPython 3.11–3.14 build
listed in the pinned uv catalog, preferably a supported security patch.
Changing uv requires reviewed pins for its official ZIP, uv.exe and
two license files. Changing CPython (or selecting a different build through
uv) requires the SHA-256 of the exact CPython archive selected by the catalog.
Never replace a pin just to suppress a mismatch.

Examples for project.dependencies (choose one list):
    dependencies = []
    dependencies = ["more-itertools==11.1.0"]
    dependencies = ["openpyxl>=3.1,<4", "polars"]
Bare names/ranges select versions on this machine. Compatible pure Python,
Windows AMD64 native and stable-ABI wheels are supported. No source builds,
custom indexes, direct URLs or git/path dependencies. Without a uv.lock next
to SETUP.bat, SETUP resolves from PyPI; later resolutions can differ.
Avoid dependency markers based on platform_version or platform_release.
If they select different packages on the target, START rejects the inventory
mismatch. Prepare for a matching Windows environment instead.

Double-click SETUP.bat, or from the extracted starter root:
    .\SETUP.bat

SETUP checks the uv archive, executable, license files and exact CPython
archive against SHA-256 pins before using them. uv extracts Python from the
verified local archive while offline. SETUP then locks package versions,
checks downloaded wheels against uv.lock, and tests an
offline install without a persistent cache and records the installed
package names and versions from that throwaway venv. No app is run.
SETUP produces bundle/ for inspection and prepared-app.zip for transfer.
The verified ZIP is published only after it has been completely written and
checked. Temporary files stay under the starter, not Windows Temp.
Only one SETUP can run in a starter folder at a time. The empty
.prepare.lock file is not part of the bundle and may remain between runs.
Read setup.log in the starter for the latest attempt's steps and errors,
and bundle/provenance.json for each verified download's URL and SHA-256.
Unexpected origins, mismatched hashes and failed checks stop SETUP.
SETUP will not overwrite an existing bundle/ or prepared-app.zip.

To reproduce the prepared payload, use the same starter, application files
and pyproject.toml in a fresh folder. Copy a trusted bundle/uv.lock next to
SETUP.bat before starting. SETUP checks and keeps that lock, never silently
resolving again. Identical payload bytes and the same Python build produce
the same automated ZIP; file order and timestamps are fixed.

Transfer only prepared-app.zip; no manual archiving is needed. SETUP prints
the ZIP SHA-256 in the console and records it in setup.log. Send the hash
through a trusted channel separately. The ZIP uses standard DEFLATE with
UTF-8 filenames where needed and no wrapper folder or encryption. Very large
archives can require ZIP64. Other operating systems can read the ZIP, but
the packaged app still targets Windows 11 x64. Review app files for secrets
before transfer; internal hashes are not an independent signature.

2. OFFLINE TARGET MACHINE

Copy prepared-app.zip locally and verify its SHA-256 against the trusted
expected value. In PowerShell:
    Get-FileHash -LiteralPath .\prepared-app.zip -Algorithm SHA256

If it matches, extract into a
fresh directory on a local fixed drive. Double-click START.bat. No network
access is needed or used by the launcher: uv runs with --offline,
--no-config, --no-python-downloads and --no-index during wheel sync.
It verifies payload files on first start or rebuild, creates .venv from
runtime/ at the extraction path, and uses uv to select local wheels for
the locked versions and hashes. No persistent uv cache is kept. Later
starts check the interpreter, isolation settings and installed package
names/versions, then skip installation. This is not a file-by-file audit:
missing or damaged package contents can still fail at import time.

Do not transfer a .venv or move the initialized folder. Move the ZIP or
unstarted bundle instead. If the configuration or app payload needs to
change, make a fresh bundle online. Keep the shipped files unchanged and
put writable inputs/results in data/ (created by START before running the
app) or outside the bundle. START does not
rehash application or runtime files on every run. Use sys.executable for
Python subprocesses; plain "python" can select a different interpreter.
The technical launcher displays combined, line-oriented stdout/stderr.
Full-screen console apps and ANSI cursor/colour control are not guaranteed.

To recover a damaged or interrupted .venv, stop the app and move only the
.venv directory outside the bundle. Run START.bat again. It verifies the
payload and recreates the environment offline, leaving data/ alone. No
need to re-extract unless the payload itself is missing or damaged.

An arbitrary folder name is fine within normal Windows path limits;
no network shares, junctions, or symlinks. START exit: 0 success,
10 environment failure, 20 application failure, 30 wrapper failure.

WHAT IS IN THE PREPARED FOLDER

START.bat and two PowerShell files: offline initialization/launch.
application/: your code and static data.
uv.exe, runtime/, wheelhouse/: the third-party binaries and wheels.
pyproject.toml, uv.lock: chosen settings and resolved dependency record.
install-plan.txt: uv-exported hashed installation input, not a second lock.
bundle-manifest.json: relative paths, shipped file hashes and package inventory.
provenance.json, LICENSE, THIRD_PARTY.md, licenses/: origins and notices.
.venv/ and .portable-python/ are created only by START; never zip them.

SETUP DOWNLOADS (NOT ACCESSED BY START)

https://releases.astral.sh/github/uv/releases/download/0.13.6/uv-x86_64-pc-windows-msvc.zip
https://releases.astral.sh/github/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-x86_64-pc-windows-msvc-install_only_stripped.tar.gz
https://pypi.org/simple/ and https://files.pythonhosted.org/packages/...
https://raw.githubusercontent.com/astral-sh/uv/0.13.6/LICENSE-MIT
https://raw.githubusercontent.com/astral-sh/uv/0.13.6/LICENSE-APACHE

Exact artifact URLs appear during SETUP and in provenance.json / uv.lock.
Bootstrap redirects must stay on official HTTPS Astral/GitHub release hosts;
wheel URLs must be on files.pythonhosted.org and may not redirect. TLS
verification stays enabled. The initial uv.lock resolution trusts PyPI
metadata over HTTPS; those metadata responses are not separately pinned.
Release signatures for the default uv and CPython archives are checked when
reviewing the pins, not by the launcher. Review dependencies before transfer,
including any known advisories; SETUP does not query an advisory service.
Wheels can execute code. The venv is not a sandbox; keep target networking
blocked by host policy if your app or libraries must never access it.
Python and wheel notices remain with the shipped bytes. Review the licenses
and any additional redistribution obligations before distributing a bundle.
