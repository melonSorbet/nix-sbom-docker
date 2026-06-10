#!/usr/bin/env python3

from __future__ import annotations

import json
from collections import Counter, deque
from pathlib import Path
from urllib.parse import urlparse

import click
from rich.console import Console

out = Console()


def short(path: str) -> str:
    """Strip the /nix/store/<hash>- prefix and trailing .drv from a store path."""
    if path.startswith("/nix/store/"):
        rest = path[len("/nix/store/") :]
        if "-" in rest:
            rest = rest.split("-", 1)[1]
        path = rest
    if path.endswith(".drv"):
        path = path[: -len(".drv")]
    return path


def wrap_names(names: list[str], indent: str = "  ", width: int = 90) -> list[str]:
    line, lines, w = "", [], 0
    for n in names:
        piece = (", " if line else indent) + n
        if w + len(piece) > width and line:
            lines.append(line)
            line, w = indent + n, len(indent + n)
        else:
            line += piece
            w += len(piece)
    if line:
        lines.append(line)
    return lines


def topo_build_order(deps: list[dict]) -> list[str]:
    edges = {d["ref"]: list(d.get("dependsOn") or []) for d in deps}
    indeg: Counter[str] = Counter()
    nodes: set[str] = set(edges.keys())
    for u, vs in edges.items():
        for v in vs:
            indeg[v] += 1
            nodes.add(v)
    q = deque(sorted(n for n in nodes if indeg[n] == 0))
    topo: list[str] = []
    while q:
        n = q.popleft()
        topo.append(n)
        for v in edges.get(n, []):
            indeg[v] -= 1
            if indeg[v] == 0:
                q.append(v)
    topo.reverse()
    return topo


@click.command()
@click.argument(
    "pbom_file",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
)
@click.option(
    "--order",
    type=int,
    default=8,
    metavar="N",
    show_default=True,
    help="Number of build steps to show at each end of the trace (0 = hide).",
)
def main(pbom_file: Path, order: int) -> None:
    """One-screen PBOM report aimed at a thesis-defense audience."""
    pbom = json.loads(pbom_file.read_bytes())
    components = pbom.get("components", [])
    deps = pbom.get("dependencies", [])
    props = {
        p["name"]: p["value"]
        for p in pbom.get("metadata", {}).get("properties", [])
    }
    subject = pbom.get("metadata", {}).get("component", {}) or {}
    subject_name = subject.get("name", "?")
    subject_drv = props.get("nix:topLevelDrv", "?")

    total = len(components)
    required = [c for c in components if c.get("scope") == "required"]
    excluded = [c for c in components if c.get("scope") == "excluded"]
    pct_in_image = (100.0 * len(required) / total) if total else 0.0

    out.print()
    out.rule(
        f"[bold]PBOM Report[/bold]  ·  [green]{subject_name}[/green]  ·  "
        f"built by {props.get('nix:version','?')}"
    )
    out.print()
    out.print(
        f"  [bold]This build touched [yellow]{total}[/yellow] components.[/bold]"
    )
    out.print(
        f"  The runtime artifact contains [green]{len(required)}[/green] of them "
        f"({pct_in_image:.1f}%)."
    )
    out.print(
        f"  The remaining [red]{len(excluded)}[/red] are invisible to any "
        f"image scanner."
    )
    out.print()

    out.rule("[cyan]Build identity[/cyan]", align="left")
    flake_rev = props.get("nix:flakeLockedRev")
    rev_str = flake_rev if flake_rev else "[dim]? (tree was dirty at emit time)[/dim]"
    out.print(f"  subject       [green]{subject_name}[/green]")
    out.print(f"  top-level drv {short(subject_drv)}")
    out.print(f"  nix version   {props.get('nix:version','?')}")
    out.print(f"  flake ref     {props.get('nix:flakeRef','?')}")
    out.print(f"  flake rev     {rev_str}")
    out.print(f"  NAR hash      {props.get('nix:flakeLockedNarHash','?')}")
    out.print(f"  profile       [yellow]{props.get('pbom:profile','?')}[/yellow]")
    out.print()

    out.rule(
        f"[cyan]Runtime components[/cyan] "
        f"[dim]({len(required)} — what an image scanner can see)[/dim]",
        align="left",
    )
    for line in wrap_names(sorted(c["name"] for c in required)):
        out.print(line)
    out.print()

    hosts: Counter[str] = Counter()
    for c in components:
        for p in c.get("properties") or []:
            if p.get("name") == "nix:fetch_url":
                h = urlparse(p["value"]).hostname or "?"
                hosts[h] += 1
    if hosts:
        out.rule(
            "[cyan]Supply-chain ingestion[/cyan] "
            f"[dim]({sum(hosts.values())} fetches across "
            f"{len(hosts)} hosts)[/dim]",
            align="left",
        )
        for host, n in hosts.most_common(10):
            out.print(f"  [magenta]{n:>5}[/magenta]  {host}")
        out.print()

    hub_count: Counter[str] = Counter()
    for d in deps:
        for ref in d.get("dependsOn") or []:
            hub_count[ref] += 1
    if hub_count:
        out.rule(
            "[cyan]Build hubs[/cyan] "
            "[dim](most-depended-on derivations — concentration risk)[/dim]",
            align="left",
        )
        for ref, n in hub_count.most_common(8):
            pct = 100.0 * n / total if total else 0
            annot = (
                f"  [dim]← {pct:.0f}% of derivations depend on this[/dim]"
                if pct >= 50
                else ""
            )
            out.print(f"  [magenta]{n:>5}[/magenta]  {short(ref)}{annot}")
        out.print()

    if order > 0 and deps:
        topo = topo_build_order(deps)
        head = min(order, len(topo))
        out.rule(
            f"[cyan]How it was built[/cyan] "
            f"[dim]({len(topo)} steps · first {head} + last {head} · "
            f"one valid leaf-first order)[/dim]",
            align="left",
        )
        for i, n in enumerate(topo[:head], 1):
            out.print(f"  [magenta]{i:>5}[/magenta]  {short(n)}")
        if len(topo) > 2 * head:
            out.print(f"  [dim]      ... {len(topo) - 2 * head} more ...[/dim]")
        tail_start = max(head, len(topo) - head)
        for offset, n in enumerate(topo[tail_start:], 1):
            out.print(f"  [magenta]{tail_start + offset:>5}[/magenta]  {short(n)}")
        out.print()

    out.rule("[bold]The claim[/bold]")
    out.print()
    big_hubs = sum(1 for v in hub_count.values() if v >= 100)
    fetches = sum(hosts.values())
    out.print(
        f"  Image scanners see [green]{len(required)}[/green] runtime components."
    )
    out.print(
        f"  This PBOM additionally enumerates [yellow]{len(excluded)}[/yellow] "
        f"build-only inputs, [magenta]{fetches}[/magenta] external fetches,"
    )
    out.print(
        f"  and [red]{big_hubs}[/red] load-bearing derivations (each "
        f"depended on by 100+ others)."
    )
    out.print()
    out.print(
        "  [bold]That gap is the supply-chain attack surface no image "
        "scanner can see.[/bold]"
    )
    out.print()


if __name__ == "__main__":
    main()
