#!/opt/homebrew/bin/python3
from __future__ import annotations

import csv
import sys
from pathlib import Path


def normalize(text: str) -> str:
    return " ".join((text or "").replace("\r", " ").replace("\n", " ").split()).strip()


def ensure_csv(csvfile: Path) -> None:
    csvfile.parent.mkdir(parents=True, exist_ok=True)
    if not csvfile.exists():
        with csvfile.open("w", newline="", encoding="utf-8-sig") as f:
            csv.writer(f).writerow(["description", "author", "posted_time", "url"])


def cmd_check(csvfile: Path, desc: str, author: str) -> int:
    ensure_csv(csvfile)
    key = normalize(desc) + "||" + normalize(author)
    with csvfile.open("r", newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            row_key = normalize(row.get("description", "")) + "||" + normalize(row.get("author", ""))
            if row_key == key:
                print("FOUND")
                return 0
    print("NOT_FOUND")
    return 0


def cmd_append(csvfile: Path, desc: str, author: str, posted: str, url: str) -> int:
    ensure_csv(csvfile)
    key = normalize(desc) + "||" + normalize(author)
    clean_url = (url or "").strip()
    if "http" not in clean_url:
        print("MISSING_HTTP")
        return 0
    seen_urls = set()
    seen_keys = set()
    with csvfile.open("r", newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            seen_urls.add((row.get("url") or "").strip())
            seen_keys.add(normalize(row.get("description", "")) + "||" + normalize(row.get("author", "")))
    if clean_url and clean_url not in seen_urls and key not in seen_keys:
        with csvfile.open("a", newline="", encoding="utf-8-sig") as f:
            csv.writer(f).writerow([desc, author, posted, url])
        print("APPENDED")
    else:
        print("DUPLICATE_OR_EMPTY")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("USAGE_ERROR", file=sys.stderr)
        return 2
    command = argv[1]
    csvfile = Path(argv[2])
    if command == "check":
        if len(argv) != 5:
            print("USAGE_ERROR", file=sys.stderr)
            return 2
        return cmd_check(csvfile, argv[3], argv[4])
    if command == "append":
        if len(argv) != 7:
            print("USAGE_ERROR", file=sys.stderr)
            return 2
        return cmd_append(csvfile, argv[3], argv[4], argv[5], argv[6])
    print("UNKNOWN_COMMAND", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
