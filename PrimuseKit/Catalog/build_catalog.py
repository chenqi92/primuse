"""Compile the pinned AutoEq snapshot into the read-only database shipped by PrimuseKit."""
import collections
import json
import lzma
from pathlib import Path
import sqlite3
import tempfile
import unicodedata


def normalized(name):
    folded = unicodedata.normalize("NFD", name.casefold())
    return "".join(c for c in folded if c.isalnum())


def compile_catalog(source, database):
    entries = source["entries"]
    recommended = [row["name"] for row in entries if row["recommended"]]
    if source["schema"] != 1 or len(source["revision"]) != 40:
        raise ValueError("Unsupported AutoEq snapshot")
    if len(recommended) != source["recommendedCount"] or len(set(recommended)) != len(recommended):
        raise ValueError("Each model must have one recommended profile")
    if set(recommended) != {row["name"] for row in entries}:
        raise ValueError("Missing recommended profile")
    database.executescript("""
        CREATE TABLE snapshot(revision TEXT NOT NULL, recommendedCount INTEGER NOT NULL);
        CREATE TABLE profiles(
            id TEXT NOT NULL UNIQUE, name TEXT NOT NULL, measurementSource TEXT NOT NULL,
            measurement TEXT NOT NULL, path TEXT NOT NULL, revision TEXT NOT NULL,
            recommended INTEGER NOT NULL, preamp REAL NOT NULL, filters TEXT NOT NULL
        );
        CREATE INDEX profilesByModel ON profiles(name);
        CREATE TABLE models(name TEXT NOT NULL, normalized TEXT NOT NULL, shortName TEXT NOT NULL, sources TEXT NOT NULL);
        CREATE TABLE aliases(name TEXT PRIMARY KEY, profileID TEXT NOT NULL) WITHOUT ROWID;
    """)
    database.execute("INSERT INTO snapshot VALUES (?, ?)", (source["revision"], source["recommendedCount"]))
    variants = {normalized(row["name"].split(" (", 1)[0]) for row in entries if " (" in row["name"]}
    aliases = collections.defaultdict(set)
    sources = collections.defaultdict(set)
    for row in entries:
        sources[row["name"]].add(normalized(row["measurement"]))
    for row in entries:
        database.execute("INSERT INTO profiles VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (
            row["id"], row["name"], row["measurementSource"], row["measurement"], row["path"],
            row["revision"], row["recommended"], row["preamp"], json.dumps(row["filters"], separators=(",", ":")),
        ))
        name = normalized(row["name"])
        if not row["recommended"]:
            continue
        short_name = normalized(" ".join(row["name"].split()[1:]))
        database.execute("INSERT INTO models VALUES (?, ?, ?, ?)", (
            row["name"], name, short_name, "|".join(sorted(sources[row["name"]])),
        ))
        if name not in variants:
            for alias in {name, short_name}:
                if alias:
                    aliases[alias].add(row["id"])
    database.executemany("INSERT INTO aliases VALUES (?, ?)", (
        (name, next(iter(ids))) for name, ids in sorted(aliases.items()) if len(ids) == 1
    ))
    database.commit()


if __name__ == "__main__":
    directory = Path(__file__).resolve().parent
    resources = directory.parent / "Sources/PrimuseKit/Resources"
    destination = resources / "AutoEqCatalog.sqlite.lzma"
    uncompressed = resources / "AutoEqCatalog.sqlite"
    with tempfile.TemporaryDirectory(dir=resources) as temp:
        candidate = Path(temp) / "AutoEqCatalog.sqlite"
        db = sqlite3.connect(candidate)
        try:
            compile_catalog(json.loads((directory / "AutoEqCatalog.json").read_bytes()), db)
        finally:
            db.close()
        compressed = Path(temp) / destination.name
        compressed.write_bytes(lzma.compress(candidate.read_bytes(), format=lzma.FORMAT_XZ, preset=6))
        compressed.replace(destination)
    if uncompressed.exists():
        uncompressed.unlink()
