# Third-party components

The MIT license in this repository covers the original launchers, examples,
tests, build script, and documentation. It does **not** relicense downloaded
software or users' applications/notebooks.

The release ZIPs contain only this project's text source and notices. They do
not redistribute uv executables, CPython archives, wheels, or a prepared venv.
Those components are fetched directly from upstream during setup.

| Component | Default | Upstream license / reference |
|---|---|---|
| uv | 0.13.6 | Apache-2.0 OR MIT; [upstream license](https://github.com/astral-sh/uv#license) |
| CPython | 3.13.18 | PSF license agreement and included third-party notices; [Python licensing](https://docs.python.org/3.13/license.html) |
| python-build-standalone | selected through pinned uv | Build-system source is MPL-2.0; binary distributions have CPython and bundled-library terms, not one blanket MPL license; [build source](https://github.com/astral-sh/python-build-standalone/blob/main/LICENSE), [distribution metadata](https://github.com/astral-sh/python-build-standalone/blob/main/docs/distributions.rst) |
| JupyterLab | 4.6.4 | BSD-3-Clause; [upstream license](https://github.com/jupyterlab/jupyterlab/blob/v4.6.4/LICENSE) |
| ipykernel | 7.4.0 | BSD-3-Clause; [upstream license](https://github.com/ipython/ipykernel/blob/v7.4.0/LICENSE) |

JupyterLab's Python dependencies and bundled frontend assets have their own
licenses. The installed distributions carry their license metadata/notices;
preserve them. Extra user-selected libraries may use different licenses.

Basic review: these upstream licenses do not require changing this independent
MIT-licensed bootstrap to their license merely because it downloads and runs
them. This is a limited source/metadata check, not a legal opinion or an audit
of every transitive package. If you redistribute a **prepared** runtime or
environment, perform a separate component/license review, retain all required
notices, and satisfy any applicable source/offering obligations. Do not assume
that downloading a package from PyPI makes its license permissive.
