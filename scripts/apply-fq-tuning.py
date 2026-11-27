#!/usr/bin/env python3
"""Tune Linux sch_fq defaults for high-BDP aggressive BBR + Pixie paths."""

import hashlib
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"apply-fq-tuning: {message}")


def require_once(source: str, text: str, label: str) -> None:
    count = source.count(text)
    if count != 1:
        fail(f"expected exactly one {label}, found {count}")


def replace_once(source: str, old: str, new: str, label: str) -> str:
    require_once(source, old, label)
    return source.replace(old, new, 1)


if len(sys.argv) not in {2, 3}:
    fail("usage: apply-fq-tuning.py SCH_FQ_C [PROVENANCE_ENV]")

source_path = Path(sys.argv[1]).resolve()
provenance_path = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else None
if not source_path.is_file() or source_path.name != "sch_fq.c":
    fail(f"not a stock sch_fq source file: {source_path}")

source = source_path.read_text()
stock_sha256 = hashlib.sha256(source.encode()).hexdigest()

# Raise sch_fq default packet limits and flow hash buckets so high-BDP
# non-TSO/tunnel/WireGuard/QUIC/retransmit bursts do not trigger local
# flows_plimit drops that feed back into Pixie loss compensation.
source = replace_once(
    source,
    "\tsch->limit\t\t= 10000;",
    "\tsch->limit\t\t= 32768;",
    "sch_fq default global packet limit",
)
source = replace_once(
    source,
    "\tq->flow_plimit\t\t= 100;",
    "\tq->flow_plimit\t\t= 2000;",
    "sch_fq default per-flow packet limit",
)
source = replace_once(
    source,
    "\tq->fq_trees_log\t\t= ilog2(1024);",
    "\tq->fq_trees_log\t\t= ilog2(4096);",
    "sch_fq default flow hash buckets",
)
source = replace_once(
    source,
    'MODULE_DESCRIPTION("Fair Queue Packet Scheduler");',
    'MODULE_DESCRIPTION("Fair Queue Packet Scheduler (high-BDP tuned defaults)");',
    "sch_fq module description",
)

for required in [
    "\tsch->limit\t\t= 32768;",
    "\tq->flow_plimit\t\t= 2000;",
    "\tq->fq_trees_log\t\t= ilog2(4096);",
    'MODULE_DESCRIPTION("Fair Queue Packet Scheduler (high-BDP tuned defaults)");',
]:
    if source.count(required) != 1:
        fail(f"missing tuned sch_fq output marker: {required}")

source_path.write_text(source)
tuned_sha256 = hashlib.sha256(source.encode()).hexdigest()

if provenance_path:
    provenance_path.write_text(
        f"FQ_STOCK_SOURCE_SHA256={stock_sha256}\n"
        f"FQ_TUNED_SOURCE_SHA256={tuned_sha256}\n"
        "FQ_DEFAULT_PLIMIT=32768\n"
        "FQ_DEFAULT_FLOW_PLIMIT=2000\n"
        "FQ_DEFAULT_BUCKETS=4096\n"
    )

print(
    "Applied high-BDP sch_fq defaults: limit=32768, flow_plimit=2000, "
    "buckets=4096."
)
