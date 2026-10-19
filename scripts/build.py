"""Build the two source-only Windows ZIPs; no network or package installation."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    "python": (
        "portable-python-one-launcher",
        ["START.bat", "portable-python.ps1", "pyproject.toml", "README.txt",
         "application/__init__.py", "application/__main__.py"],
    ),
    "jupyterlab": (
        "portable-python-jupyterlab",
        ["START.bat", "portable-jupyter.ps1", "pyproject.toml", "README.txt",
         "notebooks/WELCOME.ipynb"],
    ),
}
UV_VERSION = "0.13.1"
UV_ARCHIVE_SHA256 = "3b2661a463a5baea7f5076ea2b25ab71d77f36a6c0d809e5350651792f80a672"
UV_EXE_SHA256 = "4075a09490327d2bedfacc807fa48252fb93647c5bd7ef28f00e579160ea3fb5"


def check_profile(name, files):
    source = ROOT / name
    actual = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()}
    if actual != set(files) or any(p.is_symlink() for p in source.rglob("*")):
        raise ValueError(f"Unexpected or linked source files in {name}: {actual ^ set(files)}")
    metadata = tomllib.loads((source / "pyproject.toml").read_text(encoding="utf-8"))
    project = metadata["project"]
    assert project["version"] == "0.1.0"
    assert project["requires-python"] == "==3.13.16"
    assert project["dependencies"] == []
    assert metadata["tool"]["uv"]["required-version"] == f"=={UV_VERSION}"
    assert metadata["tool"]["uv"]["package"] is False
    assert metadata["tool"]["uv"]["index"] == [
        {"name": "pypi", "url": "https://pypi.org/simple", "default": True}
    ]
    assert metadata["tool"]["portable-python"] == {
        "uv-archive-sha256": UV_ARCHIVE_SHA256,
        "uv-exe-sha256": UV_EXE_SHA256,
    }
    if name == "jupyterlab":
        assert metadata["dependency-groups"] == {
            "jupyter": ["jupyterlab==4.6.4", "ipykernel==7.4.0"]
        }
    else:
        assert "dependency-groups" not in metadata

    shell = shutil.which("pwsh") or shutil.which("powershell.exe")
    if shell is None:
        raise RuntimeError("PowerShell is required for syntax validation")
    for relative in files:
        path = source / relative
        text = path.read_text(encoding="utf-8")
        if text.startswith("\ufeff"):
            raise ValueError(f"Unexpected BOM: {relative}")
        if path.suffix == ".py":
            compile(text, relative, "exec")
        elif path.suffix == ".ipynb":
            notebook = json.loads(text)
            assert notebook["nbformat"] == 4
            for cell in notebook["cells"]:
                assert cell.get("id")
                if cell["cell_type"] == "code":
                    assert cell["execution_count"] is None and cell["outputs"] == []
                    compile("".join(cell["source"]), relative, "exec")
        elif path.suffix == ".ps1":
            # No user content is interpolated into this PowerShell program.
            parser = (
                "$t=$null; $e=$null; "
                "[void][System.Management.Automation.Language.Parser]::ParseFile("
                "$env:PORTABLE_PYTHON_SOURCE,[ref]$t,[ref]$e); "
                "if($e.Count){$e|ForEach-Object{Write-Error $_};exit 1}"
            )
            import os
            environment = dict(os.environ, PORTABLE_PYTHON_SOURCE=str(path))
            subprocess.run([shell, "-NoProfile", "-Command", parser], env=environment, check=True)
    return project["version"]


def build(profile, output):
    prefix, files = PROFILES[profile]
    version = check_profile(profile, files)
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"{prefix}-{version}-windows-x86_64.zip"
    entries = [(name, ROOT / profile / name) for name in files]
    entries += [(name, ROOT / name) for name in ("LICENSE", "THIRD_PARTY.md")]
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path in entries:
            assert not name.startswith("/") and ".." not in Path(name).parts
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 19, 0, 0, 0))
            info.create_system = 3  # Fixed ZIP host metadata across build platforms.
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            content = path.read_bytes().replace(b"\r\n", b"\n")
            if name.endswith(".bat"):
                content = content.replace(b"\n", b"\r\n")
            archive.writestr(info, content)
    with zipfile.ZipFile(destination) as archive:
        assert archive.testzip() is None
        assert archive.namelist() == [name for name, _ in entries]
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    print(f"{destination.name}: {destination.stat().st_size} bytes; SHA256 {digest}")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["all", *PROFILES], default="all")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    for profile in PROFILES if args.profile == "all" else [args.profile]:
        build(profile, args.output.resolve())


if __name__ == "__main__":
    main()
