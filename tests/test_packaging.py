"""Regression test for the Windows/PyPI console entry point."""

import ast
import subprocess
import sys
import zipfile
from pathlib import Path


def test_wheel_contains_importable_entry_point(tmp_path):
    project_root = Path(__file__).resolve().parents[1]
    subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "wheel",
            "--no-deps",
            "--no-build-isolation",
            "--wheel-dir",
            str(tmp_path),
            str(project_root),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    wheel = next(tmp_path.glob("edlclient-*.whl"))
    with zipfile.ZipFile(wheel) as archive:
        names = set(archive.namelist())
        assert "edl.py" in names
        assert "edlclient/edl.py" in names
        entry_points = next(n for n in names if n.endswith(".dist-info/entry_points.txt"))
        assert "edl = edlclient.edl:run" in archive.read(entry_points).decode("utf-8")
        for name in ("edl.py", "edlclient/edl.py"):
            ast.parse(archive.read(name).decode("utf-8"), filename=name)
        assert "../edl.py" not in archive.read("edlclient/edl.py").decode("utf-8").splitlines()
