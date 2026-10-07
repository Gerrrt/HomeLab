#!/usr/bin/env python3
"""Print a throwaway copy of a stack's Loki config, every path inside <work>.

Shared by check_loki_rules.sh (do the rules parse?) and test_loki_rules.py (do
they match what they should?), so both boot Loki on the settings production
uses and differ from it only where a scratch run must.

--for-tests adds what the behaviour tests need on top of that. Every one of
them exists because the fixtures are pushed with timestamps hours or days in
the past, and must stay queryable from the ingester for the length of a run:

  querier.query_ingesters_within: 0
    With the default of 3h the querier does not ask the ingester about anything
    older than three hours, so every older fixture comes back empty. A firing
    case then fails, and worse, a quiet case passes over data it never saw.
    0 means always ask the ingester.

  ingester.max_chunk_age: 168h, ingester.chunk_retain_period: 1h
    A chunk is flushed once its first entry is older than max_chunk_age (2h by
    default), and every fixture chunk is, so the 30s flush loop takes them
    straight to the store. chunk_retain_period (0s by default) then drops them
    from memory before the store's index can serve them, and for the rest of
    the run the lines are nowhere. That is the likeliest reading of the first
    CI run (#893): the streams checked first came through and a stream of
    8-10h-old lines checked after them never did. Each setting closes the gap
    on its own. max_chunk_age also sets the out-of-order window (half of it),
    and wider is harmless here.

Usage: loki_scratch_config.py <loki-config.yaml> <work-dir> [--for-tests]
"""

import pathlib
import sys

# PyYAML from the one pinned bootstrap, scripts/_deps.py (#848).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _deps import require_yaml

yaml = require_yaml()


def scratch(cfg: dict, work: str, for_tests: bool = False) -> dict:
    cfg["common"]["path_prefix"] = f"{work}/data"
    cfg["common"]["storage"]["filesystem"] = {
        "chunks_directory": f"{work}/data/chunks",
        "rules_directory": f"{work}/data/rules",
    }
    cfg["storage_config"]["tsdb_shipper"] = {
        "active_index_directory": f"{work}/data/index",
        "cache_location": f"{work}/data/cache",
    }
    cfg["storage_config"]["filesystem"] = {"directory": f"{work}/data/chunks"}
    cfg["compactor"]["working_directory"] = f"{work}/data/compactor"
    cfg["ruler"]["storage"]["local"]["directory"] = f"{work}/rules"
    cfg["ruler"]["rule_path"] = f"{work}/data/rules-temp"
    if for_tests:
        cfg.setdefault("querier", {})["query_ingesters_within"] = "0"
        ingester = cfg.setdefault("ingester", {})
        ingester["max_chunk_age"] = "168h"
        ingester["chunk_retain_period"] = "1h"
    return cfg


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(args[0], encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    yaml.safe_dump(scratch(cfg, args[1], "--for-tests" in argv), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
