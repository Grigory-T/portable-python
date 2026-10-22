# portable-python

Two small, transparent Python launchers for **Windows 11 x86-64 (AMD64)**.
No preinstalled Python or uv. No administrator installation. No global PATH
or registry changes. Initial setup requires Internet access.

## Download, unpack, run

1. Download one ZIP from **[Releases](../../releases/latest)** (not GitHub's
   automatic “Source code” archive).
2. Unpack into a new folder on a local fixed drive.
3. Double-click **START.bat**.

First start downloads and verifies uv and CPython, installs packages into a
local `.venv`, then runs the example or opens JupyterLab in your browser.
Keep the console open while the program/server is running. First preparation
can take several minutes; unchanged later starts skip package setup.

| ZIP | Purpose | Put your code here |
|---|---|---|
| `portable-python-one-launcher-0.1.2-windows-x86_64.zip` | Ordinary Python application | `application/`; entry point `__main__.py` |
| `portable-python-jupyterlab-0.1.2-windows-x86_64.zip` | Interactive notebooks | `notebooks/`; create or copy `.ipynb` files |

Both are usable immediately. The application example uses only the standard
library. The notebook example checks its actual interpreter and directory.
The ZIPs contain readable text source, not an opaque installer or executable.

Only these two general tools are maintained. Customize application/notebook
content and `pyproject.toml`, not a project-specific copy of the bootstrap.
**START.bat is the sole normal user entry point** for both first preparation
and subsequent sessions; there is no separate required SETUP step.

## Supported environment

This is a **Windows-specific bootstrap**, not a universal Python distribution.
The following applies to both ZIPs; the application/libraries may add requirements.

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
| Network | First setup and package changes need DNS and HTTPS access to official sources. Ethernet, Wi-Fi or mobile Internet are equivalent. VPN/proxy use is conditional on working access/authentication. |
| Permissions | Standard user with permission to write the folder and execute downloaded EXEs/DLLs and PowerShell. No administrator install; organization-enforced controls are not overridden. |
| JupyterLab | A modern JavaScript-enabled browser and permitted loopback HTTP/WebSocket connections. Server and browser run locally; no public listening port is required. |

Unchanged later starts need no setup download; offline use still depends on
what the app/notebooks do. Package availability, CPU instructions, native DLLs,
drivers, resource limits and organization policy are not hidden guarantees.
See [environment details and limitations](docs/ENVIRONMENT.md).

## Python and libraries

Default pins: **CPython 3.13.16**, **uv 0.13.4**; the notebook edition adds
**JupyterLab 4.6.4** and **ipykernel 7.4.0**. The user-library list is empty.
These are deliberately selected/tested pins, not an auto-update mechanism.

Before first start, edit the supplied `pyproject.toml`, retaining its metadata:

```toml
[project]
name = "portable-python-one-launcher"
version = "0.1.2"
description = "General Windows portable Python application"
requires-python = "==3.13.16"
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

## Two lifecycles

- **Application:** first START prepares, then runs `python -m application`.
  Later starts only validate/run. For changed Python/library/launcher settings,
  use a fresh extraction; source code may change independently.
- **JupyterLab:** START prepares if needed, then serves on `127.0.0.1` with
  token authentication. To change libraries, stop server/kernels, edit TOML,
  then START again. Notebooks are retained. Closing the browser does not stop
  the server; use **File > Shut Down** or Ctrl+C in the console.

Jupyter checks installed packages locally before skipping setup and prints
installed versions of declared user libraries. Save changes in this extraction's
TOML, stop its server, then START again. If the browser does not open, copy the
**full localhost URL including its token** from the console; keep it private.

Both distinguish setup failure (overall code `10`) from app/server failure
(`20`), with `0` success and `30` launcher failure. Local JSONL journals record
infrastructure progress/status; notebook contents and application output are
not deliberately copied into those journals.

## Scope and safety

- Run only trusted application/notebook code and reviewed packages, as a normal
  Windows user, in a private local project folder. Code runs with that user's
  filesystem/network permissions; this is not a sandbox or malware scanner.
- First setup deliberately resolves packages live on the target. `uv.lock`
  records that result; it is not a pre-audited dependency graph shipped in the
  ZIP. CI checks its test installations against OSV, not arbitrary future graphs.
- Windows 11 AMD64 with 64-bit Windows PowerShell 5.1 is the tested target.
  Linux, macOS, ARM64, 32-bit Windows and offline first setup are not supported.
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
and the limits of the security claims. Use a fresh extraction for v0.1.2;
do not overwrite an older prepared environment.

## Source layout and development

```text
python/       application ZIP source
jupyterlab/   notebook ZIP source
scripts/      offline release builder
tests/        Windows acceptance tests
docs/         download and security review details
```

Build machine: Python 3.11+ and PowerShell parser (`pwsh` or `powershell.exe`):

```text
python scripts/build.py
```

This deterministic, network-free build checks the explicit source allowlist,
TOML, Python/notebook syntax and PowerShell syntax, then creates only two ZIPs
under `dist/`. Each includes LICENSE and THIRD_PARTY.md. CI additionally runs
fresh Windows setup/application/kernel acceptance, using only upstream Internet
downloads. See [testing](docs/TESTING.md).

## License

Original project code: **[MIT](LICENSE)**. Downloaded components keep their own
licenses; see [third-party review](THIRD_PARTY.md). There are no bundled third-
party binaries in the source repository or these release ZIPs.
