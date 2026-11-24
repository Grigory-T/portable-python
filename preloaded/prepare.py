"""Online preparation helpers. Not shipped in a prepared target bundle."""

import hashlib
import json
from pathlib import Path
import re
import sys
import tomllib
from urllib.parse import unquote, urlsplit
from urllib.request import build_opener, HTTPRedirectHandler


def read_toml(path):
    return tomllib.loads(path.read_text(encoding="utf-8"))


def validate_project(path, python, uv):
    data = read_toml(path)
    if set(data) != {"project", "tool"} or set(data["tool"]) != {"uv", "portable-python"}:
        raise ValueError("Only project and the supplied tool tables are supported")
    project = data["project"]
    if set(project) != {"name", "version", "description", "requires-python", "dependencies"}:
        raise ValueError("Use only the supplied project fields")
    if project["requires-python"] != f"=={python}":
        raise ValueError("requires-python must match the selected exact CPython")
    if data["tool"]["uv"] != {
        "package": False, "required-version": f"=={uv}",
        "index": [{"name": "pypi", "url": "https://pypi.org/simple", "default": True}],
    }:
        raise ValueError("Only the supplied PyPI-only uv settings are supported")
    pins = data["tool"]["portable-python"]
    if set(pins) != {
        "uv-archive-sha256", "uv-exe-sha256", "uv-license-mit-sha256",
        "uv-license-apache-sha256", "python-archive-sha256",
    } or not all(isinstance(value, str) and re.fullmatch(r"[a-fA-F0-9]{64}", value) for value in pins.values()):
        raise ValueError("Use exactly the supplied SHA-256 pins")
    requirements = project["dependencies"]
    if not isinstance(requirements, list) or any(
        not isinstance(req, str)
        or not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*(?:\s*(?:\[|[<>=!~;])|$)", req)
        or any(c in req for c in "@:/\\\n\r")
        for req in requirements
    ):
        raise ValueError("Use ordinary PyPI requirements, not URLs, paths or custom sources")


def wheel_url(url):
    parts = urlsplit(url)
    if (parts.scheme, parts.netloc) != ("https", "files.pythonhosted.org") or not parts.path.startswith("/packages/") or parts.query or parts.fragment:
        raise ValueError(f"Unexpected wheel origin: {url}")
    name = unquote(parts.path.rsplit("/", 1)[-1])
    if not re.fullmatch(r"[A-Za-z0-9_+.\-]+\.whl", name):
        raise ValueError("Invalid wheel filename")
    return name


def compatible_wheel(name, version):
    """Prefilter on normal CPython Windows AMD64; uv is final tags/markers authority."""
    _, python, abi, platform = name[:-4].rsplit("-", 3)
    if not {"win_amd64", "any"}.intersection(platform.split(".")):
        return False
    _, minor, _ = map(int, version.split("."))
    interpreters = set(python.split("."))
    abis = set(abi.split("."))
    exact = f"cp3{minor}"
    if exact in interpreters and {exact, "abi3", "none"}.intersection(abis):
        return True
    if "abi3" in abis and any(f"cp3{i}" in interpreters for i in range(2, minor)):
        return True
    return "none" in abis and any(tag in interpreters for tag in
                                 ["py3", *(f"py3{i}" for i in range(minor + 1))])


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Wheel download unexpectedly redirected")


def download_wheels(bundle, version):
    source = read_toml(bundle / "uv.lock")
    wheels = {}
    for package in source["package"]:
        if package["source"] == {"virtual": "."}:
            continue
        if package["source"] != {"registry": "https://pypi.org/simple"}:
            raise ValueError("uv.lock contains a non-PyPI package")
        for wheel in package.get("wheels", []):
            url = wheel["url"]
            name = wheel_url(url)
            digest = wheel["hash"]
            if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
                raise ValueError("Expected a SHA-256 wheel pin from uv.lock")
            if compatible_wheel(name, version):
                value = (url, digest.removeprefix("sha256:"))
                if wheels.setdefault(name, value) != value:
                    raise ValueError("Conflicting hashes or URLs for the same wheel")

    wheelhouse = bundle / "wheelhouse"
    wheelhouse.mkdir()
    opener = build_opener(NoRedirect)
    provenance_path = bundle / "provenance.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    for name, (url, expected) in sorted(wheels.items()):
        print(f"Download: {url}", flush=True)
        # TLS verification is on; select no insecure fallback or other index.
        target = wheelhouse / name
        with opener.open(url, timeout=60) as response, target.open("xb") as output:
            digest = hashlib.sha256()
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        actual = digest.hexdigest()
        if actual != expected:
            raise ValueError(f"Wheel failed locked SHA-256 verification: {name}")
        print(f"SHA-256 VERIFIED: {name} {actual}", flush=True)
        provenance["downloads"].append(
            dict(file=f"wheelhouse/{name}", url=url, sha256=actual, verification="uv.lock SHA-256")
        )
    provenance_path.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(f"Verified wheel files: {len(wheels)}")


def write_manifest(bundle, inventory):
    files = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_file():
            with path.open("rb") as stream:
                files[path.relative_to(bundle).as_posix()] = hashlib.file_digest(stream, "sha256").hexdigest()
    (bundle / "bundle-manifest.json").write_text(
        json.dumps({
            "schema": 2,
            "installed_packages": Path(inventory).read_text(encoding="utf-8").splitlines(),
            "sha256": files,
        }, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    mode, path, *args = sys.argv[1:]
    if mode == "validate":
        validate_project(Path(path), *args)
    elif mode == "wheels":
        download_wheels(Path(path), *args)
    elif mode == "manifest":
        write_manifest(Path(path), *args)
    else:
        raise SystemExit("Unknown preparation operation")
