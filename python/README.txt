PORTABLE PYTHON - APPLICATION PROFILE
=====================================
Review revision: 2026-10-29. Main template for ordinary Python applications.
Extract freshly; do not overlay an older prepared environment.

QUICK START
-----------
Machine: target Windows 11 x86-64 machine, with approved Internet access.

1. Copy the ZIP to a local fixed drive; extract it into a new project folder.
2. Edit Python and application libraries in pyproject.toml BEFORE first START.
3. Put all application code below application/. __main__.py is the entry point.
4. Run START.bat. First start downloads/prepares everything, then runs the app.
5. Use the same START.bat for subsequent runs.

There is no preinstalled Python/uv requirement and no administrator install.
The transport has no executables, runtime, wheels, lock, environment, or cache.
Do not execute it from SMB/UNC/mapped drives. All generated state stays local.
Folder names may contain spaces/non-ASCII characters; keep paths short enough
for Windows. The launcher's child process does not change your parent shell.

TRUST MODEL
-----------
Use a private local project folder, trusted application code and reviewed
packages. Run as a normal Windows user, not administrator. Python code and
dependencies run with that user's filesystem/network permissions and can read
other inherited environment variables/secrets. This is not a sandbox or scanner.
The first package graph is resolved live from PyPI, not pre-audited or frozen
inside the ZIP. Review names/versions; hashes verify bytes, not benign behavior.
Generated state must not be edited or copied from an untrusted environment.

FILES AND CONTEXT
-----------------
START.bat                  user entry point, preserves category code and pauses
portable-python.ps1        technical bootstrap, validation, and application run
pyproject.toml             exact Python/uv, uv hashes, user dependencies
application/__init__.py    normal package marker
application/__main__.py    python -m application entry point
README.txt                 this contract

The extracted folder containing START.bat and TOML is the project root.
All application code can be nested below application/. No input/output folder
is created by the framework; data paths are an application decision.

PYTHON / PACKAGES
-----------------
The defaults are CPython 3.13.18, uv 0.13.6, and NO third-party packages.

Edit only the intended values under [project], for example:
  requires-python = "==3.13.18"
  dependencies = ["openpyxl", "xlrd", "polars"]

Or:
  dependencies = [
      "pandas",
      "numpy==2.4.2",
      "openpyxl>=3.1,<4",
      "matplotlib~=3.10.0",
      "colorama; sys_platform == 'win32'",
  ]

No version: newest compatible at setup; ==: exact; >=,<: range;
~=3.10.0: >=3.10.0,<3.11; marker after semicolon: conditional.
Standard-library modules (sys, pathlib, re, subprocess, etc.) need no entry.
Only ordinary PyPI requirements and compatible wheels are accepted, not direct
URLs/paths, extra groups, custom indexes, uv sources, or source builds.

Verified managed-Python choices in this uv catalog:
  requires-python = "==3.13.18"   default
  requires-python = "==3.12.16"
  requires-python = "==3.11.18"
Other exact CPython 3.11-3.14 patches work only if present in this pinned catalog
and compatible with your libraries. Ranges are not valid runtime selections.

[tool.uv].required-version = "==0.13.6" is the exact uv pin. The matching archive
and executable hashes live in [tool.portable-python]. Keep supplied pins unless
you have independently verified replacement versions/hashes. These are tested
pins, not a promise that they are the latest releases or vulnerability-free.

LIFECYCLE
----------
First START:
  verify/download uv -> install managed CPython under project state
  -> validate TOML -> uv lock -> check official origins
  -> uv sync --locked --no-build -> dependency/runtime/module checks
  -> record ready.state -> PORTABLE PYTHON RESULT: READY
  -> execute application -> APPLICATION RESULT

Later unchanged START:
  validate versions, state hashes, uv executable and local base interpreter
  -> setup SKIPPED -> execute application (no uv/install/download setup work)

Python, library declarations, lock, and launcher are immutable after preparation.
For changes, extract a fresh ZIP, edit TOML/copy application code, and START.
The application code itself may be edited without setup if dependencies stay
unchanged. Retry a failed initial setup in the same folder after correcting a
configuration/network problem. Initial cold setup may take several minutes.

Do NOT place pip/subprocess installation code inside application startup.
uv owns dependency preparation; normal application execution does not mutate it.
Ad-hoc installs outside TOML are unrecorded and not part of the lock contract.
Only one launcher may use the same workspace at a time.

APPLICATION EXECUTION
---------------------
From the project root, the launcher executes:
  .venv\Scripts\python.exe -u -E -s -B -X utf8 -m application

-u: immediate stdout/stderr; -E: ignore PYTHON* overrides; -s: no user site;
-B: do not create .pyc; -X utf8: UTF-8 mode; -m: run package as a module.
-I/-P are not used here: the adjacent application package must be importable.

UTF-8 console contract: the launcher sets PowerShell native-output decoding to
UTF-8 for Python/uv stdout and stderr, and restores the prior console encoding
in finally on exit/failure. No Windows regional setting or profile is changed.
Normal Unicode print() calls need no sys.stdout/sys.stderr.reconfigure block.
No errors='replace' policy is imposed: invalid application text is not silently
turned into question marks. Console font glyph coverage remains a host concern.
Blank native stderr lines remain blank, not PowerShell RemoteException type
names. Progress/warnings on stderr do not by themselves mean failure; the child
exit code determines success. Carriage-return progress may appear as lines.

Python interpreter flags are not inherited by child processes. Use the same
venv Python and explicit UTF-8 flags for Python workers, for example from the
project root with a worker at application/worker.py:

  subprocess.run(
      [sys.executable, '-u', '-E', '-s', '-B', '-X', 'utf8',
       '-m', 'application.worker'],
      check=True, capture_output=True, text=True, encoding='utf-8',
  )

The parent must import sys and subprocess. File encodings are a separate
contract: specify encoding='utf-8' for UTF-8 text files and choose the actual
encoding of legacy data. This does not repair already-corrupted text, native
programs emitting other encodings, or libraries that replace standard streams.
No activation or PATH lookup is required. The working directory is project root.
Infrastructure runtime checks use -I instead, avoiding project-root startup
hooks during validation. Installed .pth/site hooks and dependencies remain trusted.

Example application/__main__.py:
  from .entrypoint import main
  if __name__ == "__main__":
      raise SystemExit(main())

Both imports work inside a package:
  from .services.reports import build_report
  from application.services.reports import build_report

Use __init__.py in regular imported subpackages. Nesting is supported within
Windows path limits. Imported module names should be valid Python identifiers.
For resources:
  from pathlib import Path
  RESOURCE = Path(__file__).resolve().parent / "resources" / "template.json"

Save Python/TOML as UTF-8, preferably without BOM. No encoding cookie/shebang
is needed for normal UTF-8 Python. LF/CRLF are both accepted. Execute via START,
not by opening __main__.py directly, to retain package-relative imports.

STATE AND LOGS
---------------
Generated locally:
  .venv/             installed environment; NEVER transport/move independently
  uv.lock            resolved packages, artifact URLs, hashes, platform markers
  .portable-python/
      uv.exe         verified manager
      python/        base managed CPython; .venv depends on this location
      cache/         disposable uv cache
      temp/          local temporary state
      project-policy.py   generated TOML validator
      ready.state    versions plus TOML/lock/launcher fingerprints
      workspace.lock lock held only while setup/application is running
      portable-python.log UTF-8 JSONL infrastructure journal

python-bin/ is reserved and normally absent (--no-bin). Temporary uv download
and extraction files are removed after successful verification.
The marker detects configuration drift; it is NOT a full installed-file audit.
Do not remove the base runtime while retaining .venv. Recreate a prepared
workspace at a new location rather than treating .venv as relocatable.

The journal records neutralized infrastructure commands/timings and exit status,
not application output/data. Application stdout/stderr is streamed to console
with known account/project path substitutions; this is not a universal data
anonymizer. Review any logs/output before sharing them.

Overall codes:
  0   portable Python ready, application successful
  10  setup/environment/configuration failure; app not run
  20  application failure; original child code printed/journaled
  30  launcher failure
Console has separate PORTABLE PYTHON RESULT and APPLICATION RESULT blocks.

OFFICIAL INTERNET SOURCES / VERIFICATION
----------------------------------------
uv executable archive:
  https://releases.astral.sh/github/uv/releases/download/0.13.6/uv-x86_64-pc-windows-msvc.zip
Archive SHA-256:
  a2a8820d5eea32f08ef467ef3b7f66883a9b076d5737a2fc2fbb5f458d1bb50f
Extracted uv.exe SHA-256:
  81ea623608f8c17720c62efd0a380a8ead380c4d365ba6968e9d279a2319c674
Review references (not automatic extra downloads):
  https://github.com/astral-sh/uv/releases/tag/0.13.6
  https://releases.astral.sh/github/uv/releases/download/0.13.6/uv-x86_64-pc-windows-msvc.zip.sha256

Default CPython archive from uv's embedded catalog:
  https://releases.astral.sh/github/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-x86_64-pc-windows-msvc-install_only_stripped.tar.gz
Provider/reference:
  https://github.com/astral-sh/python-build-standalone
  https://www.python.org/downloads/release/python-31318/

Package index/metadata:
  https://pypi.org/simple
  https://pypi.org/simple/<normalized-package-name>/
Wheels:
  https://files.pythonhosted.org/packages/...

PowerShell downloads uv over HTTPS with current-user proxy credentials; BITS
AutoDetect/SystemDefault with Negotiate is the fallback. The trusted TOML hash
is checked before extraction, and uv.exe is hashed before execution. uv selects
the exact HTTPS releases.astral.sh Python record and verifies its catalog hash.
uv lock resolves metadata; uv sync verifies artifact hashes from uv.lock.
All package origins must be HTTPS pypi.org/files.pythonhosted.org. Exact
transitive URLs/hashes are generated in uv.lock. No fixed IP/proxy is embedded;
DNS and redirects may introduce additional destinations.

Python/packages use uv's client, NOT the bootstrap BITS fallback. Windows PAC/
Negotiate behavior is not guaranteed in uv; browser success does not prove
setup connectivity. HTTP(S)_PROXY is retained; inherited UV_* overrides are
cleared. --no-config avoids unrelated uv configuration; --system-certs uses
Windows trust; TLS verification is never disabled. Source builds are disabled
during lock/sync. Inaccessible approved sources cause an explicit failure.
SSL_CERT_FILE/SSL_CERT_DIR overrides are cleared in the child process, so they
cannot silently replace the Windows trust store. Approved roots must be in the
Windows store; keep Windows/root certificates current. Parent shell is unchanged.
A fresh setup can resolve different transitive versions at a later date; keep
the generated lock as the installed environment's audit record.

TECHNICAL COMMANDS
-------------------
Machine: target Windows machine, PowerShell in local extracted project root.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\portable-python.ps1 -NoPause
Preparation only, without app:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\portable-python.ps1 -SetupOnly -NoPause

ExecutionPolicy Bypass applies only to that child process, not machine policy.
For interactive notebooks use the separate portable-python-jupyterlab template,
rather than treating its mandatory Jupyter group as an application library list.
