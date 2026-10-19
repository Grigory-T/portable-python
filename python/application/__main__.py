"""Example application entry point for ``python -m application``."""

import platform

from . import __version__


def main() -> int:
    print("Portable Python application started successfully")
    print(f"Application: {__package__} {__version__}")
    print(f"Python:      {platform.python_version()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
