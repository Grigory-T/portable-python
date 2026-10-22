PORTABLE PYTHON JUPYTERLAB PROFILE
==================================

PURPOSE
-------

This is a small Windows 11 x86-64 bootstrap for a project-local JupyterLab
environment. The ZIP contains no uv executable, CPython, package wheels,
virtual environment, lock file, cache, or user data. First start downloads and
prepares everything from official sources. Later starts reuse the local state.
Review revision: 2026-10-22. Extract this revision into a new folder; do not
overlay launchers on an older prepared environment.

The user-library list is empty by default. JupyterLab and ipykernel are
mandatory infrastructure in a separate dependency group; they are not counted
as user notebook libraries.

TRUST MODEL
-----------
Use trusted notebooks/packages in a private local folder, as a normal Windows
user. Notebook/app code can access that user's files, network and inherited
environment secrets. A venv and notebooks/ are not security sandboxes.
First setup resolves the transitive graph live from PyPI; it is not a fixed,
pre-audited graph inside the ZIP. Hashes check bytes, not package behavior.
Do not copy generated config/runtime files from other environments.

USER PROCEDURE
--------------

Machine: target Windows 11 x86-64 machine with Internet access.

1. Copy the ZIP to a local fixed drive and extract it into a new folder.
2. Review pyproject.toml before first start:
     requires-python       exact CPython version
     project.dependencies additional notebook libraries; [] means none
     tool.uv.required-version exact uv version (keep the supplied pin)
3. Copy existing .ipynb files anywhere below notebooks/, or keep WELCOME.ipynb.
4. Run START.bat.
5. Wait for setup. JupyterLab starts in the foreground and requests opening the
   default browser. If Windows does not open it, use the displayed local URL.
6. Work only below notebooks/ in JupyterLab's file browser.
7. Stop the server with JupyterLab File > Shut Down, or Ctrl+C in the console.
8. Use START.bat for every later session.

Spaces and non-ASCII folder names are supported. The extracted folder is the
project root: it contains START.bat and pyproject.toml. The notebook workspace
is its notebooks/ child. Keep paths reasonably short for Windows tools.

Do not run the batch or PowerShell file from SMB, a mapped network drive, or a
UNC path. Copy/extract locally first. The browser may be closed independently,
but closing the browser does not stop the JupyterLab server.

TRANSPORTED FILES
-----------------

  START.bat                normal user entry point
  portable-jupyter.ps1     technical download/setup/server launcher
  pyproject.toml           Python, user libraries, and Jupyter infrastructure
  notebooks/WELCOME.ipynb  standard-library environment check and workspace
  README.txt               this contract

GENERATED LOCALLY
-----------------

  .portable-jupyter/  verified uv, managed Python, cache, Jupyter state, log
  .venv/              uv-created project environment
  uv.lock             exact target-generated dependency resolution

The .venv is created in its final folder and is never transported. The
notebooks/ tree is user data and is never removed or synchronized by setup.

.portable-jupyter/ contains uv.exe; python/ (base CPython); cache/ (uv cache);
jupyter-config/, jupyter-data/ (including the local python3 kernelspec),
jupyter-runtime/ (server/kernel connections and browser links), ipython/,
temp/, generated project-policy.py and project-kernel.py, ready.state,
workspace.lock, and portable-jupyter.log. Optional Matplotlib state is directed
to matplotlib/ only if a notebook actually uses that library; it is not
installed by default. python-bin/ is reserved and normally absent (--no-bin).
Do not share runtime connection files: they contain authentication material.
portable-server.json also contains a fresh random session token. It is written
with Jupyter's secure-write helper, never passed in command-line arguments or
copied to the diagnostic journal. Tokens rotate at every launcher invocation.
Unexpected auto-loaded jupyter*_config.py/json files in the generated config
directory cause a safe failure. Use fresh extraction, not custom base config.

uv.lock records exact resolved packages, artifact URLs and hashes. ready.state
records the selected Python/uv/Jupyter versions and hashes of pyproject.toml,
uv.lock, and the launcher; it allows unchanged starts to skip setup. Runtime
validation also checks that the .venv base interpreter belongs to this project.
This is a consistency check, not a hash audit of every installed package file.
Do not move a prepared workspace: recreate it at the new location and copy
only notebooks/user data. Keep both the base python/ runtime and .venv/.

PYTHON VERSION
--------------

The exact selection is the standard [project] field in pyproject.toml:

  requires-python = "==3.13.16"

Preferred verified Windows x86-64 choices for this profile are:

  requires-python = "==3.13.16"   default
  requires-python = "==3.11.17"
  requires-python = "==3.12.15"

These exact builds were present in uv 0.13.4's managed-Python catalog when the
ZIP was built. The launcher also accepts another exact CPython 3.11-3.14 patch
version when uv's pinned catalog supplies a Windows x86-64 build and Jupyter's
dependencies resolve for it. Exact notation is required; ranges are rejected.

The supplied uv pin is standard metadata:

  [tool.uv]
  required-version = "==0.13.4"

Its matching archive/executable hashes are in [tool.portable-python]. Changing
uv requires independently verified matching hashes as well, not just a new
version string. This profile deliberately retains its tested Python/Jupyter
pins; it does not mean they are the newest upstream versions.

USER LIBRARIES AND VERSION NOTATION
-----------------------------------

EDIT [project].dependencies, NOT [dependency-groups].jupyter.
The jupyter group must retain jupyterlab==4.6.4 and ipykernel==7.4.0.
For example, to add spreadsheet/data libraries, the two sections should be:

  [project]
  name = "portable-python-jupyterlab"
  version = "0.1.1"
  description = "General Windows target-resolved portable JupyterLab environment"
  requires-python = "==3.13.16"
  dependencies = ["openpyxl", "xlrd", "polars"]

  [dependency-groups]
  jupyter = ["jupyterlab==4.6.4", "ipykernel==7.4.0"]

Keep the following [tool.uv], [tool.portable-python], and index tables unchanged.
This is an example only; the supplied template keeps dependencies = [].
If configuration validation fails, fix TOML and rerun START in the same folder;
verified runtime downloads are reused. Do not remove notebook infrastructure.

The default list is deliberately empty:

  dependencies = []

Examples:

  dependencies = [
      "pandas",
      "numpy==2.4.2",
      "openpyxl>=3.1,<4",
      "matplotlib~=3.10.0",
      "colorama; sys_platform == 'win32'",
  ]

Meaning:

  pandas              newest compatible version during target resolution
  numpy==2.4.2        exact version
  openpyxl>=3.1,<4    bounded range
  matplotlib~=3.10.0 compatible release, >=3.10.0 and <3.11
  ; marker            conditional dependency

Use ordinary PyPI requirement strings only. Direct URLs, custom indexes,
tool.uv.sources, duplicate entries, and source builds are rejected.

ADDING OR REMOVING LIBRARIES
----------------------------

Canonical simple method:

1. Stop JupyterLab and all notebook kernels.
2. Edit project.dependencies in pyproject.toml.
3. Run START.bat again.
4. The launcher reports Setup: UPDATED, runs uv lock and exact uv sync, then
   starts JupyterLab. Existing notebooks remain unchanged.

Example after first setup: change dependencies = [] to

  dependencies = ["pandas", "openpyxl>=3.1,<4"]

Stop the server, save the file, then double-click START.bat. No separate build
machine or requirements.lock is needed. Removing an entry and restarting
removes it during exact synchronization unless another package still needs it.
The notebooks/ tree is preserved, including nested copied notebooks.

Do not put pip/subprocess installation calls in notebook startup code. uv is
the package manager for this profile. Ad-hoc uv-pip installs are unrecorded and
may disappear on the next exact sync; use pyproject.toml for persistent changes.

START AND SERVER LIFECYCLE
--------------------------

First START.bat:

  download/hash-check uv
    -> uv downloads exact managed CPython
    -> uv lock resolves Jupyter plus user libraries from official PyPI
    -> uv sync creates .venv from compatible wheels
    -> runtime/Jupyter checks
    -> JupyterLab binds to 127.0.0.1 and opens the browser

Later unchanged START.bat:

  validate prepared state
    -> Setup: SKIPPED
    -> start JupyterLab without setup/download activity

Changed pyproject.toml:

  validate detects change
    -> Setup: UPDATED
    -> incrementally re-lock/sync the same .venv
    -> start JupyterLab

JupyterLab runs in the foreground. Final `JUPYTERLAB RESULT` and `START STATUS`
appear only after the server stops. Normal server logs and a tokenized localhost
URL remain visible in the console while it runs. The server is explicitly bound
to 127.0.0.1; this profile does not expose it to the LAN.

Only one launcher/server may use a workspace at a time. A second START fails
with an explicit already-in-use message instead of updating a live environment.
First setup needs Internet and can take several minutes (especially uv lock);
later unchanged starts do not resolve/install packages. If the browser does
not open, use the tokenized localhost URL shown by Jupyter in the console.

This is deliberately different from a fixed application's separate SETUP/START
profile: notebook library edits are supported in place. -SetupOnly is the
technical preparation-only mode when the two phases should be run separately.

NOTEBOOK PYTHON AND WORKING DIRECTORY
------------------------------------

No activation or global kernel registration is needed. The launcher runs:

  .venv\Scripts\python.exe -u -E -s -B -X utf8 -m jupyterlab

It supplies a local server configuration, notebooks/ root, loopback binding,
and browser settings. -u streams output immediately; -E ignores PYTHON*
environment overrides; -s excludes user site-packages; -B avoids .pyc writes;
-X utf8 selects UTF-8 mode; -m invokes the module with the project interpreter.

The only exposed kernel is Python (project .venv), named python3. Its absolute
interpreter is .venv/Scripts/python.exe, with the same isolation/UTF-8 flags.
This prevents an existing global kernelspec from selecting another Python.
For a copied notebook naming an unavailable kernel, choose Python (project
.venv) in JupyterLab. Do not install/register a global kernel for this workspace.

In a notebook, this standard-library check shows the actual context:

  import sys
  from pathlib import Path
  print(sys.executable)
  print(Path.cwd())

A notebook at notebooks/example.ipynb normally starts in notebooks/. A nested
notebook at notebooks/reports/example.ipynb starts in notebooks/reports/.
Relative data paths and nearby .py imports use that kernel working directory,
not automatically the project root. Example: helper.py next to the notebook
can be imported with import helper. For a multi-file library, use ordinary
packages with __init__.py and put their parent on sys.path explicitly if it is
not the current directory. Relative package imports (from .helpers import ...)
belong inside a package module, not directly in an un-packaged notebook cell.
Save .py and TOML as UTF-8, preferably without BOM. Normal UTF-8 Python needs
no shebang or encoding cookie. Nested notebooks/packages are supported, within
Windows path-length limits. This tool does not install your notebook code.

The notebooks/ browser root is navigation scope, NOT a filesystem sandbox.
Notebook code runs with your Windows permissions; review copied notebooks
before execution and configure their inputs/outputs deliberately. Keep all
runtime data and outputs local; never point them at a network transport share.

This public edition uses Jupyter's read-only extension manager and disables
built-in news/update polling. Install notebook libraries through TOML/uv, not
an independent extension/package installer. Normal token authentication remains
enabled; the server is not a security sandbox for arbitrary notebook code.

EXIT-CODE CONTRACT
------------------

  Overall 0    setup/validation succeeded; server stopped normally
  Overall 10   portable-Python/setup failure; JupyterLab not started
  Overall 20   prepared environment ready; JupyterLab server failed
  Overall 30   batch/PowerShell launcher failure

The persistent diagnostic log is:

  .portable-jupyter\portable-jupyter.log

The UTF-8 JSONL journal records infrastructure steps, elapsed command time,
setup/server status, and exit codes. Known account/project paths are redacted.
Server token URLs and notebook output are not deliberately copied into it.
Jupyter's own foreground console can show local paths and authentication URLs;
do not publish that console or runtime files without reviewing them.

OFFICIAL SOURCES AND VERIFICATION
---------------------------------

uv 0.13.4:

  release:
    https://github.com/astral-sh/uv/releases/tag/0.13.4
  Windows x86-64 archive:
    https://releases.astral.sh/github/uv/releases/download/0.13.4/uv-x86_64-pc-windows-msvc.zip
  official checksum:
    https://releases.astral.sh/github/uv/releases/download/0.13.4/uv-x86_64-pc-windows-msvc.zip.sha256
  pinned archive SHA-256:
    ccec7508a07d9933d7cb1261880633efcf1f30d6e6eddab21823f1dae6f23225
  pinned extracted uv.exe SHA-256:
    b9d9656370ee1812e53e985d8bbb81870038106df98ef34cb45bcf4e0fe0df17

Managed CPython:

  provider:
    https://github.com/astral-sh/python-build-standalone
  artifacts:
    https://releases.astral.sh/github/python-build-standalone/
  exact default archive selected by uv 0.13.4:
    https://releases.astral.sh/github/python-build-standalone/releases/download/20261013/cpython-3.13.16%2B20261013-x86_64-pc-windows-msvc-install_only_stripped.tar.gz
  CPython reference (not an installer download by this tool):
    https://www.python.org/downloads/release/python-31316/

uv selects and verifies the managed-Python distribution. The launcher rejects
selected Python URLs outside HTTPS releases.astral.sh and prints the exact URL.

Python packages:

  index: https://pypi.org/simple
  per-package metadata: https://pypi.org/simple/<normalized-package-name>/
  files: https://files.pythonhosted.org/
  JupyterLab: https://pypi.org/project/jupyterlab/
  ipykernel: https://pypi.org/project/ipykernel/

Only official PyPI lock origins are accepted. TLS verification stays enabled,
and --no-build prevents source builds during lock/sync. Compatible wheels are
required. Exact transitive artifact URLs and hashes are written to uv.lock;
uv verifies those hashes when installing. The uv bootstrap download uses a
pinned SHA-256 and supports Windows integrated proxy authentication without
storing a proxy password.

The official checksum URL is a review reference: the launcher uses the trusted
hashes already in TOML, not a hash downloaded alongside the archive. uv verifies
CPython against its embedded catalog checksum. All configured download origins
are releases.astral.sh, pypi.org, and files.pythonhosted.org. Redirects/DNS may
use additional hosts or changing IPs; no IP/proxy address is hardcoded.

The uv archive is downloaded using PowerShell's current-user proxy credentials,
then BITS AutoDetect/SystemDefault with Negotiate as a fallback. Python and
packages use uv's HTTP client, NOT that BITS fallback. uv does not guarantee
Windows PAC/integrated proxy authentication: browser success alone is not a
download test. Standard HTTP(S)_PROXY settings are retained; inherited UV_*
source/runtime overrides are cleared. --no-config avoids unrelated uv settings,
and --system-certs uses the Windows trust store. No insecure TLS bypass is used.
If required official resources are inaccessible, setup fails explicitly.
SSL_CERT_FILE/SSL_CERT_DIR and BROWSER are cleared only in the launcher process:
trust comes from the current Windows certificate store; browser launch uses
the platform default rather than an inherited command. Keep Windows/root
certificates current. No global certificate or browser setting is modified.

The ZIP contains no lock on purpose: new setups resolve at that time and can
select different compatible transitive versions. uv.lock then records the local
resolution. Tested pins and SHA checks are not a guarantee that packages contain
no vulnerabilities; review dependency choices according to your own policy.

TECHNICAL OPTIONS
-----------------

Normal users use START.bat. Technical diagnostics may call:

  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\portable-jupyter.ps1 -SetupOnly
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\portable-jupyter.ps1 -NoBrowser -Port 8899

`-SetupOnly` prepares/checks the environment without starting the server.
`-NoBrowser` leaves the browser closed. `-Port` requests a specific local port.
Add -NoPause for automation. Commands run on the target machine in the locally
extracted project root. The default START requests browser opening; remote
technical tests normally use -NoBrowser and verify the local server/kernel API.

Primary documentation (references, not runtime downloads):
  https://docs.astral.sh/uv/reference/settings/#required-version
  https://docs.astral.sh/uv/concepts/projects/sync/
  https://jupyterlab.readthedocs.io/en/stable/getting_started/starting.html
  https://jupyter-client.readthedocs.io/en/stable/kernels.html
