"""Installed EDL command entry point.

Use a real Python module here instead of a symlink to ../edl.py:
Windows Git checkouts and wheel builds may not preserve that symlink.
"""

from edl import main, run


if __name__ == "__main__":
    run()
