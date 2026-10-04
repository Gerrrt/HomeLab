#!/usr/bin/env python3
"""Print a throwaway copy of a stack's Loki config, every path inside <work>.

Shared by check_loki_rules.sh (do the rules parse?) and test_loki_rules.py (do
they match what they should?), so both boot Loki on the settings production
uses and differ from it only where a scratch run must.

--for-tests adds the one setting the behaviour tests need on top of that:

  querier.query_ingesters_within: 0
    The fixtures are pushed with timestamps up to a day in the past and are
    still sitting in the ingester when they are queried; nothing has been
    flushed to the store. With the default of 3h the querier does not ask the
    ingester about anything older than three hours, so every fixture beyond
    that comes back empty. A firing case then fails, and worse, a quiet case
    passes over data it never saw. 0 means always ask the ingester.

Usage: loki_scratch_config.py <loki-config.yaml> <work-dir> [--for-tests]
"""
import sys

try:
    import yaml
except ImportError:  # check_loki_rules.sh installs it; say so if run bare
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")


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
