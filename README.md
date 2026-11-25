# portable-python

Three small, transparent Python tools for **Windows 11 x86-64 (AMD64)**.
No preinstalled Python or uv. No administrator installation. No global PATH
or registry changes. Choose online setup on the target or separate online
preparation for an offline application target.

## Download, unpack, run

1. Download one ZIP from **[Releases](../../releases/latest)** (not GitHub's
   automatic “Source code” archive).
2. Unpack into a new folder on a local fixed drive.
3. For the online application and JupyterLab, double-click **START.bat**.
   For Preloaded, first follow the two-machine workflow below.

First start downloads and verifies uv and CPython, installs packages into a
local `.venv`, then runs the example or opens JupyterLab in your browser.
Keep the console open while the program/server is running. First preparation
can take several minutes; unchanged later starts skip package setup.

| ZIP | Purpose | Put your code here |
|---|---|---|
| `portable-python-one-launcher-0.1.4-windows-x86_64.zip` | Ordinary Python application | `application/`; entry point `__main__.py` |
| `portable-python-jupyterlab-0.1.4-windows-x86_64.zip` | Interactive notebooks | `notebooks/`; create or copy `.ipynb` files |
| `portable-python-preloaded-0.1.6-windows-x86_64.zip` | Prepare a self-contained Python environment for an offline target | `application/` on the offline machine |

The online editions are usable immediately. The application examples use only the standard
library. The notebook example checks its actual interpreter and directory.
The ZIPs contain readable text source, not an opaque installer or executable.

### Preloaded: online setup machine → offline target

1. **Online Windows machine:** Extract the starter into a short local path.
   Edit `pyproject.toml` and run **SETUP.bat**. No application code is needed.
2. **Online Windows machine:** Take the generated `prepared-app.zip` and its
   SHA-256 from the console or `setup.log`. The flat ZIP contains verified uv,
   CPython, wheels, launcher, integrity manifest and hashed install plan.
   Keep the guide, `setup.log`, and `bundle-records/` on the setup machine.
3. **Offline Windows machine:** Verify the ZIP hash, extract into a fresh
   short local folder, add `input/`, `output/`, `workings/` or other files
   as needed, and add your app under `application/` with `__init__.py`
   and `__main__.py`. Run **START.bat**. It creates a local `.venv` from the
   bundled runtime, installs wheels without network, and runs the app.
   Later starts check the installed package inventory and skip installation.
   Edit code under `application/` and run START again; changing Python or
   dependencies still requires a fresh environment ZIP from SETUP.
   If the environment is damaged, move only `.venv` outside the bundle and
   run START to rebuild it offline without touching your files. Do not add
   files inside `runtime/` or `wheelhouse/`. Keep the target network blocked by policy
   if the application itself must not contact the network.

The third release ZIP is the **starter**, not the large prepared bundle. See
[the included guide](preloaded/README.txt) for commands and the file contract.

## Supported environment

This is a **Windows-specific bootstrap**, not a universal Python distribution.
The following applies to all profiles; the application/libraries may add requirements.

| Area | Support / assumption |
|---|---|
| OS | **Windows 11, 64-bit**. Windows 10/Server are outside the supported target, even if they happen to work. |
| CPU | **Intel or AMD x86-64** (`x64`, `AMD64`). No 32-bit x86, ARM/ARM64 or RISC-V support, including emulation. |
| Devices | Compatible Windows laptops/desktops. A VM must provide the same environment; no separate VM guarantee. Android/iOS phones/tablets are unsupported. |
| Other systems | Linux, WSL, macOS and their containers are unsupported. Upstream uv supporting them does not make these launchers portable to them. |
| Host tools | 64-bit **Windows PowerShell 5.1**, its .NET Framework/ZIP support and `cmd.exe`. BITS is needed only for the bootstrap download fallback. PowerShell 7 is not required. |
| Runtime/build tools | No preinstalled Python, uv, pip, compiler, SDK, Git, Node.js or Docker required. Only compatible wheels are installed; no source compilation. Windows system DLLs remain necessary; extra libraries may need external DLLs/drivers. |
| Storage | Writable local **fixed-drive** folder, SSD or HDD; SSD is faster. No network/UNC/mapped drives, removable-type drives, junctions or symlinks. Do not move a prepared environment. |
| RAM/CPU/disk | No measured project-wide minimum. Allow resources for Windows, Python, caches, installed libraries and your data. No GPU/CUDA required by the defaults; selected libraries can change this. |
| Network | Online profiles need DNS/HTTPS on first setup. Preloaded needs Internet only on its preparation machine. Ethernet, Wi-Fi or mobile Internet are equivalent if DNS/HTTPS/proxy authentication works. |
| Permissions | Standard user with permission to write the folder and execute downloaded EXEs/DLLs and PowerShell. No administrator install; organization-enforced controls are not overridden. |
| JupyterLab | A modern JavaScript-enabled browser and permitted loopback HTTP/WebSocket connections. Server and browser run locally; no public listening port is required. |

Unchanged later starts need no setup download; offline use still depends on
what the app/notebooks do. Package availability, CPU instructions, native DLLs,
drivers, resource limits and organization policy are not hidden guarantees.
See [environment details and limitations](docs/ENVIRONMENT.md).

## Python and libraries

The online editions pin **CPython 3.13.18** and **uv 0.13.6**. The notebook
edition adds **JupyterLab 4.6.4** and **ipykernel 7.4.0**. Preloaded pins
**CPython 3.15.2** and **uv 0.13.10**. User-library lists start empty.
These are deliberately selected/tested pins, not an auto-update mechanism.

The online profiles stay on the mature 3.13 line. Preloaded uses the stable
[Python 3.15.2 security release](https://www.python.org/downloads/release/python-3152/);
verify that your native packages have compatible Windows x64 wheels.
Review future security patches and rerun acceptance tests rather than
freezing a patch indefinitely. Do not self-update the pinned project-local uv.
See the [version review](docs/SECURITY-REVIEW.md).

Before first start, edit the supplied `pyproject.toml`, retaining its metadata:

```toml
[project]
name = "portable-python-one-launcher"
version = "0.1.4"
description = "General Windows portable Python application"
requires-python = "==3.13.18"
dependencies = ["openpyxl", "xlrd", "polars"]
```

`"pandas"` selects a compatible version during setup; `"pandas==3.0.5"` pins
one; `"openpyxl>=3.1,<4"` bounds a range. Standard-library imports need no entry.
Only ordinary PyPI requirements with compatible wheels are supported.

For JupyterLab, keep its supplied project name/description and **do not replace
the infrastructure group with your libraries**:

```toml
[dependency-groups]
jupyter = ["jupyterlab==4.6.4", "ipykernel==7.4.0"]
```

Own libraries always go in `[project].dependencies`. Preserve the remaining
tool/index tables. See the README inside each ZIP for version notation and
technical commands. Unavailable Python builds or wheels fail explicitly.

## Profile lifecycles

- **Application:** first START prepares, then runs `python -m application`.
  Later starts only validate/run. For changed Python/library/launcher settings,
  use a fresh extraction; source code may change independently.
- **JupyterLab:** START prepares if needed, then serves on `127.0.0.1` with
  token authentication. To change libraries, stop server/kernels, edit TOML,
  then START again. Notebooks are retained. Closing the browser does not stop
  the server; use **File > Shut Down** or Ctrl+C in the console.
- **Preloaded:** only SETUP resolves/downloads, on a separate online machine.
  Offline START initializes or reuses the target's own `.venv`.

Jupyter checks installed packages locally before skipping setup and prints
installed versions of declared user libraries. Save changes in this extraction's
TOML, stop its server, then START again. If the browser does not open, copy the
**full localhost URL including its token** from the console; keep it private.

All distinguish setup failure (overall code `10`) from app/server failure
(`20`), with `0` success and `30` launcher failure. Local JSONL journals record
infrastructure diagnostics in the online profiles. Preloaded records
preparation and the ZIP hash in `setup.log` on the setup machine; its target
diagnostics stay in the console. Application output is not journaled.

## UTF-8 output

All launchers pair Python's `-X utf8` with explicit PowerShell UTF-8 decoding
of native stdout/stderr and restore the prior console encoding in `finally`.
Ordinary Unicode `print()` calls need no application `reconfigure()` patch.
No global Windows setting or lossy `errors="replace"` policy is imposed.
Blank native stderr lines stay blank instead of becoming PowerShell exception
type names. Stderr progress/warnings are not failures by themselves; exit codes
remain authoritative.

Python workers must repeat `-X utf8`; interpreter flags are not inherited.
Use `encoding="utf-8"` when capturing their text or reading/writing UTF-8 files.
Legacy file/program encodings, replaced streams, already-corrupted text and
terminal font coverage remain separate concerns. See each ZIP's README.

## Scope and safety

- Run only trusted application/notebook code and reviewed packages, as a normal
  Windows user, in a private local project folder. Code runs with that user's
  filesystem/network permissions; this is not a sandbox or malware scanner.
- The online profiles resolve packages live on the target. Preloaded resolves
  on the setup machine and transfers its lock and wheels. Starter ZIPs do not
  contain a pre-audited dependency graph.
- Windows 11 AMD64 with 64-bit Windows PowerShell 5.1 is the tested target.
  Linux, macOS, ARM64 and 32-bit Windows are not supported.
- Run from a local folder, never directly from a network share or ZIP preview.
  Spaces/Unicode names are tested; ordinary Windows path limits still apply.
- Downloads use official Astral and PyPI sources, TLS verification and pinned
  bootstrap checksums. Source builds, custom indexes and direct URL requirements
  are not supported. See [download details](docs/DOWNLOADS.md).
- A target-generated `uv.lock` freezes the chosen dependency graph; a fresh
  setup on another date can resolve different transitive versions. A hash
  verifies bytes, **not whether a package is trustworthy**. Review package
  names, publishers, licenses and notebooks before using them.
- Jupyter exposes only its project Python kernel. Its extension installer is
  read-only; automatic news/update requests are disabled. Library changes use
  TOML/uv, not a second installer inside notebooks.
- The notebook file-browser root and venv are **not security sandboxes**.
  Python/notebooks run with your Windows permissions. Do not run untrusted code.
- No telemetry is implemented by these launchers. Setup contacts download/
  package services; third-party applications have their own behavior.
- START uses process-scoped PowerShell `ExecutionPolicy Bypass` to run the
  reviewed local launcher. It does not change persistent policy, request admin,
  disable TLS, or override organization-controlled execution restrictions.
- No guarantee of zero vulnerabilities or compatibility with every endpoint
  security/proxy policy is made. See [security policy](SECURITY.md).

See the [review decisions](docs/SECURITY-REVIEW.md) for fixes, accepted tradeoffs
and the limits of the security claims. Use a fresh extraction for v0.1.4;
do not overwrite an older prepared environment.

## Source layout and development

```text
python/       application ZIP source
jupyterlab/   notebook ZIP source
preloaded/    offline application preparation/launch source
scripts/      offline release builder
tests/        Windows acceptance tests
docs/         download and security review details
```

Build machine: Python 3.11+ and PowerShell parser (`pwsh` or `powershell.exe`):

```text
python scripts/build.py
```

This deterministic, network-free build checks the explicit source allowlist,
TOML, Python/notebook syntax and PowerShell syntax, then creates three starter ZIPs
under `dist/`. Each includes LICENSE and THIRD_PARTY.md. CI additionally runs
fresh Windows setup/application/kernel acceptance, using only upstream Internet
downloads. See [testing](docs/TESTING.md).

## License

Original project code: **[MIT](LICENSE)**. Downloaded components keep their own
licenses; see [third-party review](THIRD_PARTY.md). There are no bundled third-
party binaries in the source repository or these release ZIPs.
