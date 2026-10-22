"""Developer/CI check of this interpreter's installed PyPI package versions.

Sends package names/versions only to OSV. Not shipped or run by START.
No result is called clean if the service is unavailable or malformed.
"""

from importlib.metadata import distributions
import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.osv.dev/v1/querybatch"


def audit(packages):
    findings = []
    for offset in range(0, len(packages), 100):
        batch = packages[offset:offset + 100]
        payload = {"queries": [
            {"package": {"name": name, "ecosystem": "PyPI"}, "version": version}
            for name, version in batch
        ]}
        request = urllib.request.Request(
            ENDPOINT, data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            results = json.load(response)["results"]
        if len(results) != len(batch):
            raise ValueError("Incomplete advisory response")
        for package, result in zip(batch, results, strict=True):
            if not isinstance(result, dict) or "error" in result:
                raise ValueError("Invalid advisory response")
            for finding in result.get("vulns", []):
                findings.append((package, finding["id"]))
    return findings


def main():
    packages = sorted({(item.metadata["Name"], item.version) for item in distributions()})
    try:
        findings = audit(packages)
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
        print("Advisory check unavailable/invalid; no clean result claimed.", file=sys.stderr)
        return 2
    for (name, version), identifier in findings:
        print(f"{name}=={version}: {identifier}")
    print(f"OSV: {len(packages)} installed packages checked; {len(findings)} known advisories.")
    print("Point-in-time metadata check, not proof of safety or an audit of package code.")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
