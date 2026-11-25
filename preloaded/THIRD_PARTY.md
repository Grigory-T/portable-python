# Third-party components — Preloaded

The MIT license covers the original bootstrap, not downloaded dependencies or
your application. The starter ZIP contains only source and notices. SETUP
downloads the components below for the offline transfer ZIP.

| Component | Default | License / source |
|---|---|---|
| uv | 0.13.10 | Apache-2.0 OR MIT ([upstream](https://github.com/astral-sh/uv/tree/0.13.10#license)); license texts are in `runtime/BUNDLE-LICENSES.txt` in the transfer ZIP. |
| CPython | 3.15.2 | [PSF license and third-party notices](https://docs.python.org/3.15/license.html); retain the notices shipped with the runtime. |
| python-build-standalone | 20261124 | [Build source: MPL-2.0](https://github.com/astral-sh/python-build-standalone/blob/20261124/LICENSE); the runtime contains CPython and bundled components under their own terms. |

User-selected wheels have their own licenses; keep their notices. Review
component terms and any redistribution obligations before distributing a
prepared environment. Download provenance and hashes are in the online
`bundle-records/provenance.json`.
