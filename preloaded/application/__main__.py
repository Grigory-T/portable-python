import sys


def main() -> int:
    print(f"Portable Python application started successfully (CPython {sys.version.split()[0]}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
