#!/usr/bin/env python3
"""Move Atlas-rebased files past a future-dated migration on main."""

from datetime import datetime, timedelta
from pathlib import Path
import re
import subprocess
import sys


def git_lines(*args: str) -> list[str]:
    return subprocess.check_output(["git", *args], text=True).splitlines()


def version(path: str) -> datetime:
    match = re.match(r"^(\d{14})_.+\.sql$", Path(path).name)
    if match is None:
        raise ValueError(f"Invalid Atlas migration filename: {path}")
    return datetime.strptime(match.group(1), "%Y%m%d%H%M%S")


def main() -> None:
    migration_dir, base_ref = sys.argv[1:]
    base_files = git_lines("ls-tree", "-r", "--name-only", base_ref, "--", migration_dir)
    latest = max((version(path) for path in base_files if path.endswith(".sql")), default=None)
    rebased_files = sorted(
        git_lines("ls-files", "--others", "--exclude-standard", "--", f"{migration_dir}/*.sql"),
        key=version,
    )
    for path in rebased_files:
        candidate = version(path)
        if latest is not None and candidate <= latest:
            candidate = latest + timedelta(seconds=1)
            new_name = candidate.strftime("%Y%m%d%H%M%S") + Path(path).name[14:]
            target = Path(path).with_name(new_name)
            if target.exists():
                raise FileExistsError(f"Cannot choose a unique Atlas version: {target}")
            Path(path).rename(target)
            print(f"Moved future-skewed migration {path} to {target}")
        latest = candidate


if __name__ == "__main__":
    main()
