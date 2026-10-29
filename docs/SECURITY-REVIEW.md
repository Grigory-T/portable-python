# Security review decisions

Review date: 2026-10-29. Scope: both launchers, normal `.py` execution, generated
config, download trust, tests and release delivery. This is a limited engineering
review, not a certification, penetration test or guarantee of harmless dependencies.

## Unified UTF-8 output v0.1.4 (2026-10-29)

- Keep the tested uv 0.13.6 / CPython 3.13.18 pins, hashes and download policy.
- Both launchers set Console.OutputEncoding to UTF-8 before native calls and
  restore the original value in an outer finally spanning setup and execution.
  Python already uses -X utf8. No persistent profile/registry/region changes,
  environment-wide overrides or global replacement-character policy are added.
- The receiver must decode the producer's bytes correctly. Reconfiguring
  Python stdout again does not fix PowerShell decoding UTF-8 as a legacy code
  page. Do not hide text problems with blanket errors='replace' application code.
- Exercise actual launchers under legacy/UTF-8 code pages with Unicode success
  and failure output; verify encoding restoration in both PowerShell versions.
  Retain notebook token/authentication, local kernel and cleanup regressions.
- This contract covers normal UTF-8 streams, not arbitrary legacy native tools,
  user-replaced streams, data-file encodings or font glyph availability. Child
  Python processes must receive their own interpreter flags and text decoding.

## Security baseline v0.1.3 (2026-10-28)

- Pin uv **0.13.6** and CPython **3.13.18** for both tools. Verify the official
  uv archive digest/checksum and extracted executable hash. Confirm the default
  Windows CPython record and checksum against the pinned uv catalog and provider
  asset. Keep downloads, versions and hashes explicit in TOML and download docs.
- CPython 3.13.18 is the October 25 security release: it blocks compromised
  eMudhra intermediate CA keys in ssl and contains additional Expat, Windows
  mimetypes, tarfile and other fixes. uv 0.13.6 includes this managed runtime and
  inherits uv 0.13.5's compromised-intermediate certificate-chain rejection.
  Sources: [CPython release](https://www.python.org/downloads/release/python-31318/),
  [uv 0.13.5](https://github.com/astral-sh/uv/releases/tag/0.13.5),
  [uv 0.13.6](https://github.com/astral-sh/uv/releases/tag/0.13.6).
- The older proposed uv 0.13.5 + CPython 3.13.17 pair is compatible but is not
  the chosen security baseline. Python 3.13 is a mature security-only branch;
  use tested patch updates, not a claim of permanent safety or official LTS.
- Keep application/Jupyter behavior, pinned Jupyter infrastructure, dynamic
  target-local libraries, authentication, full token URL and offline package
  checks unchanged. Windows tests verify the new interpreter in real app/kernel
  execution. Repeated full tests use ephemeral CI with owned-workspace cleanup,
  not retained environments in user/system Temp. No host recovery data is touched.

## Reliability correction in v0.1.2

- v0.1.1's explicitly configured token made Jupyter intentionally print
  `token=...`, breaking the manual browser fallback. Restore Jupyter's built-in
  random token generation, while retaining stale-base-config refusal and
  cleared environment overrides. Test the full actual tokenized URL in console
  output, non-empty runtime token and unauthenticated API rejection.
- Before skipping Jupyter setup, run an offline locked uv environment check.
  Repair missing distributions through normal exact sync. Show installed
  versions of declared user libraries on each start. No import of user libraries
  is required by the launcher; package code remains trusted, not sandboxed.
- Test adding openpyxl then Polars, repairing a removed Polars installation,
  and real Polars computation inside the project notebook kernel. The reported
  v0.1.1 saved-edit/SKIPPED mismatch was not reproduced on the test machine;
  do not claim that its exact cause is established.
- The application launcher behavior and runtime pins are unchanged.

## Narrow changes introduced in v0.1.1

- Pin uv **0.13.4**, verifying the official asset digest, upstream checksum and
  extracted executable hash. The later-published
  [emSign advisory](https://github.com/astral-sh/uv/security/advisories/GHSA-hq85-5cpj-mr62)
  was absent from the supplied review. Windows system trust is used here; it
  must independently be current. An updated bundled CA set does not repair an
  outdated Windows trust store.
- Use isolated Python (`-I`) for infrastructure runtime/module checks. The real
  app still runs from the trusted project root with the same module command,
  so nested relative/absolute application imports remain supported.
- Clear inherited SSL_CERT_FILE/SSL_CERT_DIR, matching the documented Windows
  certificate-store policy. Clear Jupyter's BROWSER command override. Do not
  weaken TLS, remove corporate trust roots or change global settings.
- Refuse stale base Python/JSON configuration in the launcher-owned config
  directory. Test unauthenticated access rejection and a non-empty token.
  The explicit-token implementation was superseded in v0.1.2 as described above.
- Use literal .NET directory/ZIP/download APIs (avoiding PS 5.1 wildcard-path
  handling), strip diagnostic terminal controls and
  redact HTTP URL credentials. These remain limited privacy measures.
- Add tests for inherited overrides, project startup hooks, square-bracket
  paths, stale config, token rotation and authentication. Bound shutdown waits,
  check the listening port and emit redacted failure diagnostics. Forced test
  cleanup is scoped to the test-created process tree and never counts as success.
- Add a stdlib-only developer/CI OSV check of installed PyPI package versions.
  No scanner, extra installer or advisory request is added to user START.

## Assessment of the supplied recommendations

| Recommendation / claim | Decision |
|---|---|
| Ship uv.lock / pin all transitive packages | Valid for a fixed-release workflow, but deliberately not this target-resolved tool. Preserve user-selected Python/libraries and live first resolution; document the supply-chain tradeoff. |
| Wheels and notebooks can execute code | Correct, including `.pth`/site hooks. Compatible wheels and hashes are not a sandbox or malware review. |
| Stale base config can disable token auth | Valid defense-in-depth finding. Fix it even though malicious write access to the project already defeats the trust model. |
| Readable/writable folder always means code execution | Too broad: writing trusted code/config is dangerous; merely reading public source is not equivalent. Authentication files must remain private. |
| All PYTHON variables are cleared | Incorrect. Selected overrides are cleared; interpreter flags ignore Python-specific settings. Other inherited values remain accessible to code. |
| Signed commits establish publisher identity | Incomplete. Existing SSH signatures are not GitHub-verified for the neutral author. No independent signing-key trust anchor is claimed. |
| Use New-Item -LiteralPath | Not a portable fix: New-Item does not provide that parameter. Use literal .NET Directory.CreateDirectory and test bracket paths. |
| TLS 1.2 must be replaced for security | Not established. Keep the compatible TLS 1.2 bootstrap; certificate validation and current trust roots matter. TLS 1.2 alone is not a demonstrated defect. |
| More signatures/review gates/CodeQL/Dependabot | Useful in suitable workflows, not a substitute for runtime trust. Avoid adding a second signing infrastructure or mandatory multi-reviewer workflow to this small tool. PS1 is the primary runtime logic; Python-only scanning cannot certify it. |
| CI shutdown timeout proves a runtime security defect | No. Two CI failures were confirmed; the old test also passed on a separate Windows host on this date. Treat it as a real reliability/testing issue, not proof of an exploit or a diagnosed upstream regression. |

## Release and assurance limits

The repository now enables immutable future releases on GitHub; publish drafts
only after both assets are attached and verified. GitHub's release attestation shares the
GitHub trust anchor: it is not an independent author signature. Historical v0.1.0
is not retroactively made immutable by enabling the setting. Never replace
security-release bytes under an old version number.

Keep only the latest two generic delivery ZIPs in the active handoff. Users
upgrade into a fresh local folder and copy reviewed app/notebook data only.
Do not carry old venv/config/cache/readiness state into the new release.

No evidence of malicious launcher behavior was found in this inspection. That
is not a numerical risk rating or proof of no vulnerabilities. The trust model
is **trusted code + reviewed packages + private local folder + trusted updated
Windows host**, not safe execution of hostile code. Use separately managed OS
isolation when that assumption does not hold; it is not implemented here.

Primary references: [uv TLS](https://docs.astral.sh/uv/concepts/authentication/certificates/),
[Jupyter security](https://jupyter-server.readthedocs.io/en/stable/operators/security.html),
[GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases),
[OSV batch API](https://google.github.io/osv.dev/post-v1-querybatch/).
