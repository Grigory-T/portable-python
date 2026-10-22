# Environment contract

Applies to both Windows application and JupyterLab ZIPs. Reviewed 2026-10-21.
This documents the existing implementation; it does not add platform support.

## Supported target versus upstream capability

- Supported target: Windows 11 on native Intel/AMD x86-64, using 64-bit Windows
  PowerShell 5.1. `AMD64` is an architecture name, not an AMD-only requirement.
- Not supported: 32-bit Windows/processes, ARM/ARM64, RISC-V, Linux/WSL, macOS,
  Android/iOS, compatibility layers or CPU emulation. Other Windows versions
  are not supported targets, although the coarse platform check can accept them.
- Laptop versus desktop makes no difference. A Windows x86-64 VM must meet the
  same conditions; virtualization has not been independently qualified. Device
  labels do not override OS/CPU requirements.
- The code checks Windows and the process architecture, then always selects
  Windows x86-64 uv/CPython artifacts. It does not detect/select another OS or
  architecture, nor certify the Windows build, physical CPU or emulation status.
- uv and CPython support additional targets upstream; using them here would
  require a different launcher, artifacts, dependency-wheel selection and tests.

References: [uv platforms](https://docs.astral.sh/uv/reference/policies/platforms/),
[Python distributions and targets](https://gregoryszorc.com/docs/python-build-standalone/main/running.html).
Their wider support is not this project's support promise.

## Host software and permissions

- Required Windows components: `cmd.exe`, 64-bit Windows PowerShell 5.1, its
  .NET Framework (including ZIP support), normal Windows system
  APIs/DLLs, DNS, TLS and a valid certificate store. BITS/Negotiate is an optional
  fallback for downloading uv, not a requirement for a working direct download.
- START uses the explicit system Windows PowerShell path, not PowerShell 7.
  No separate Python, pip, uv, C/C++/Rust compiler, Visual Studio, .NET SDK,
  Git, Node.js, Docker or external `tar.exe` installation is required.
- A standard user must be allowed to write/create/delete files under the
  project, launch downloaded EXEs, load their DLLs and execute the reviewed
  script. No administrator install, global PATH or registry change is requested.
- Endpoint protection, application allowlisting, Windows S mode and enforced
  organization policies may prevent execution. The tool does not disable them.
  Process-scoped ExecutionPolicy Bypass is not an exemption from those controls.

## Runtime, wheels and native dependencies

- uv downloads the selected exact CPython into project-local state and creates
  the local `.venv`. System Python and user-site packages are not used.
- Windows executables/native Python extensions still depend on Windows APIs and
  DLLs. This is not a statically linked, dependency-free executable or sandbox.
- Packages must supply a compatible Windows x86-64/Python/ABI wheel (or a
  compatible platform-independent wheel). Source builds are disabled during
  resolution and synchronization; installing a compiler does not change that.
- A wheel can require external DLLs/runtimes, ODBC/database clients, GPU drivers,
  CUDA, other programs or additional CPU instructions. Those requirements belong
  to the selected package/app and are not automatically installed or checked.
  A package resolving successfully does not prove that every import/feature works.
- The default tools need no GPU/CUDA. No universal CPU-generation/instruction-set
  guarantee is made for arbitrary added libraries. Missing native dependencies
  must be resolved through the component vendor/approved administrator, never
  by downloading individual DLLs from unofficial sites.

## Filesystem and hardware

- Extract completely into a writable real folder on a local fixed drive. The
  launcher rejects network/UNC/mapped drives, junctions/symlinks and drives
  reported as removable. An external drive reported as fixed is not independently
  qualified. NTFS is the normal Windows baseline; other filesystems are untested.
- SSD and HDD are valid; SSD generally makes installation and imports faster.
  No measured minimum RAM, core count, CPU clock, free disk space or setup-time
  guarantee is published. Provision for Windows plus your actual workloads.
- ZIP size is not installed size: CPython, dependencies, caches, temporary
  downloads, notebooks and data require additional disk space. Large data/ML
  packages can greatly increase RAM, storage and download needs.
- Spaces and Unicode paths are tested; ordinary Windows/tool path-length limits
  still apply. Prefer short local paths. Cloud-synced/placeholder folders and
  filesystem redirection are not qualified; use an ordinary local folder.
- Prepared environments contain location-dependent paths. Re-extract/recreate
  at a new location; do not copy a prepared `.venv` as a portable installation.
  Only one launcher may use a project at a time. Keep the console open while running.

## Network and browser

- Connection type is irrelevant: Ethernet, Wi-Fi and mobile Internet work if
  the required requests are allowed. No specific LAN, domain, VPN, IP address,
  ISP or public inbound port is assumed.
- First preparation and dependency changes need working DNS and HTTPS to the
  official Astral/PyPI sources and their redirects/CDNs. See
  [all download origins](DOWNLOADS.md). There is no fixed bandwidth requirement;
  latency, metering, interrupted access and package size affect setup time.
- HTTPS certificates must validate, including any approved organization trust
  chain. Do not disable TLS verification. A browser download succeeding does not
  prove PowerShell/BITS or uv has equivalent proxy access/authentication.
- Bootstrap supports a Windows authenticated-proxy fallback. uv handles Python
  and package downloads using its own client; automatic PAC/Negotiate behavior
  is not guaranteed. An approved working network/proxy configuration is required.
- Unchanged later starts skip setup downloads. Application/notebook code or
  third-party packages may still require Internet; offline operation is not universal.
- Jupyter needs a modern JavaScript-enabled browser with loopback HTTP and
  WebSocket access. It binds only to `127.0.0.1` with token authentication and
  needs an available local TCP port (default Jupyter port, with retries).
  Remote browser/phone access is not provided; opening a remote server is outside
  this tool's contract. Closing the browser alone does not stop the server.

## Meaning of portability and testing

Portable means project-local Python/packages/state with no system-Python
installation, not independence from the OS, hardware, policies or native
libraries. A venv and notebook root do not restrict user-code permissions.
Separate Windows desktop acceptance and Windows CI are recorded in
[testing](TESTING.md); CI is not certification of every Windows edition,
hardware model, filesystem, proxy or user-selected package.
