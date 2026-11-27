PORTABLE PYTHON PRELOADED — Windows 11 x86-64

Both machines need 64-bit Windows PowerShell 5.1, a private writable
folder on a local fixed drive and permission to run the bundled code.
No admin install, global PATH changes, system Python, pip or compilers.

Terms: the Starter ZIP is the release download. The prepared folder is
bundle/ created by SETUP.bat. The Transfer ZIP is the final archive that the
IT specialist makes from the prepared folder after adding the application.

1. ONLINE SETUP MACHINE

Unpack the small starter ZIP into a fresh short local folder, for example
C:\apps\prep. SETUP prepares the Python environment only. It does not read
or run the application or create the Transfer ZIP.

Edit pyproject.toml before SETUP. Exact CPython and uv pins default to
3.15.2 and 0.13.10. Choose a normal Windows AMD64 CPython 3.11–3.15 build
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
custom indexes, direct URLs or git/path dependencies. Older native wheels
may not support 3.15; choose a release with a matching wheel. Without a uv.lock next
to SETUP.bat, SETUP resolves from PyPI; later resolutions can differ.
Windows wheels tagged win_amd64 target both Intel and AMD x86-64 CPUs.
Libraries can still require specific instructions. For example, if AVX2
support on the offline target machine is unknown, use Polars' official
compatibility extra in project.dependencies: "polars[rtcompat]==2.2.0".
SETUP bundles the relevant wheels; no CPU-brand detection or target download
is needed. See https://docs.pola.rs/user-guide/installation/#legacy-cpu
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
SETUP produces the prepared folder (bundle/).
bundle-records/ contains the exact pyproject.toml, uv.lock, and download
provenance.json. Those are online build records, not required on the target.
Temporary files stay under the extracted Starter ZIP, not Windows Temp.
Only one SETUP can run in a starter folder at a time. The empty
.prepare.lock file is not part of the bundle and may remain between runs.
Review setup.log in the extracted Starter ZIP folder. It records the latest
SETUP attempt that acquired the workspace lock, with UTC timestamps, phase
names, durations and a final result. Read BEGIN and PASS to follow the main
steps; DETAIL contains tool output, and ERROR identifies the failed phase.
For example:

    2026-11-27 12:34:56.789 UTC | INFO | Install CPython locally | BEGIN (local)

For artifact downloads, the log shows the request URL, HTTP response or
redirect, byte count and verified SHA-256. PyPI metadata resolution is a
separate phase with uv request/cache diagnostics; it is not a packet capture
or a hash check of PyPI metadata. It may read metadata for other platforms;
those wheels are not bundled. A supplied uv.lock skips resolution.
Unexpected artifact origins, mismatched hashes and failed checks stop SETUP.
bundle-records/provenance.json records verified artifact URLs and hashes.
SETUP omits recognized local paths, URL credentials and query values where
possible. Keep the log on the online setup machine and review before sharing.
SETUP will not overwrite existing bundle/ or bundle-records/.

To reproduce SETUP, use the same Starter ZIP and identical pyproject.toml
in a fresh folder on a compatible online setup machine. Copy the saved
bundle-records/uv.lock next to SETUP.bat before starting. SETUP preserves the
supplied lock byte for byte, checks pinned downloads and fails if a required
artifact is unavailable or no longer matches. Without a supplied lock, the
pinned uv resolves the highest compatible versions from current PyPI metadata;
the result is repeatable under the same metadata and environment, not frozen
against later PyPI changes.

Compare bundle-manifest.json SHA-256 in setup.log to identify the prepared
environment. The reproducible output is the relative file layout and bytes
under bundle/ and bundle-records/. SETUP sets generated output modification
times to 2000-01-01 00:00:00 UTC; it leaves CPython's bundled file times
untouched because its precompiled bytecode can depend on those times.
setup.log keeps real timestamps. The fingerprint includes relative file
paths, not the absolute folder used for SETUP. Filesystem creation times
and the manually created Transfer ZIP are not guaranteed to match.

After SETUP succeeds, the IT specialist:

1. Reviews the prepared folder, setup.log, and bundle-records/.
2. Adds application/ with __init__.py (which can be empty) and __main__.py
   (the entry point). Adds input/, workings/ and output/ alongside START.bat,
   and places any needed project files in those folders. Nested Python
   packages and relative imports work normally. Use UTF-8 Python source and
   paths based on __file__ or on the project folder.
3. Reviews the files for secrets or anything that should not be transferred.
   Keeps the launcher, runtime/, wheelhouse/, install-plan.txt and
   bundle-manifest.json unchanged. Retains bundled license notices.
4. Creates the Transfer ZIP outside bundle/, for example prepared-app.zip.
   In File Explorer, select the contents of bundle/ and compress them to a
   standard ZIP. Check that START.bat and all four application/data folders
   are at the ZIP root, including any empty folders. Do not ZIP the bundle/
   folder itself or include setup records, .venv/, caches or scratch files.
5. Computes SHA-256 of the final Transfer ZIP and provides the expected
   value separately through a trusted channel:
       Get-FileHash -LiteralPath .\prepared-app.zip -Algorithm SHA256
   Transfer the ZIP, not the Starter ZIP or the prepared folder.

2. OFFLINE TARGET MACHINE

Copy the Transfer ZIP locally and compare its SHA-256 with the trusted
expected value before extracting. In PowerShell:
    Get-FileHash -LiteralPath .\prepared-app.zip -Algorithm SHA256

If it matches, extract into a fresh short local folder, e.g. C:\apps\project.
Put your files in input/, then double-click START.bat. The application and
project folders are already included. START runs "python -m application"
with the project folder as its working directory.

No network access is needed or used by the launcher: uv runs with --offline,
--no-config, --no-python-downloads and --no-index during wheel sync.
It verifies payload files on first start or rebuild, creates .venv from
runtime/ at the extraction path, and uses uv to select local wheels for
the locked versions and hashes. No persistent uv cache is kept. Later
starts check the interpreter, isolation settings and installed package
names/versions, then skip installation. This is not a file-by-file audit:
missing or damaged package contents can still fail at import time.

If START is run without an app, it still prepares Python and tells you
which entry file is missing. It does not create application/, data/, or
any other user folder. User files beside the launcher are ignored by
integrity checks and preserved during recovery. Keep shipped files
unchanged; runtime/, wheelhouse/, .venv/ and .portable-python/ are reserved.
For code-only updates, IT can replace application/ and make a new Transfer
ZIP without rerunning SETUP. Python or dependency changes need a fresh SETUP.
Do not move an initialized folder or transfer .venv. Use sys.executable for
Python subprocesses; plain "python" can select a different interpreter.
The technical launcher displays combined, line-oriented stdout/stderr.
Full-screen console apps and ANSI cursor/colour control are not guaranteed.

To recover a damaged or interrupted .venv, stop the app and move only the
.venv directory outside the bundle. Run START.bat again. It verifies the
payload and recreates the environment offline, leaving user files alone. No
need to re-extract unless the payload itself is missing or damaged.

Use short paths on both machines (root at most 125 characters; shorter
is safer for deeply nested dependencies). The launcher does not change
Windows long-path settings. No network shares, junctions, or symlinks.
START exit: 0 success,
10 environment failure, 20 application failure, 30 wrapper failure.

WHAT IS IN THE PREPARED FOLDER

START.bat and two PowerShell files: offline initialization/launch.
runtime/: CPython, uv.exe and the bundled license notices.
wheelhouse/: offline wheel archives; omitted when there are no wheels.
install-plan.txt: uv-exported hashed installation input, not a second lock.
bundle-manifest.json: versions, shipped file hashes and package inventory.
.venv/ and .portable-python/ are created only by START; never zip them.
IT adds application/, input/, workings/ and output/ to the Transfer ZIP.
The Starter ZIP, setup records and this guide stay on the online setup machine.

SETUP DOWNLOADS (NOT ACCESSED BY START)

https://releases.astral.sh/github/uv/releases/download/0.13.10/uv-x86_64-pc-windows-msvc.zip
https://releases.astral.sh/github/python-build-standalone/releases/download/20261124/cpython-3.15.2%2B20261124-x86_64-pc-windows-msvc-install_only_stripped.tar.gz
https://pypi.org/simple/ and https://files.pythonhosted.org/packages/...
https://raw.githubusercontent.com/astral-sh/uv/0.13.10/LICENSE-MIT
https://raw.githubusercontent.com/astral-sh/uv/0.13.10/LICENSE-APACHE

Exact artifact URLs appear during SETUP and in bundle-records/provenance.json
and bundle-records/uv.lock on the online machine.
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
