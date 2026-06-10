#!/usr/bin/env python3

from __future__ import annotations

import datetime
import json
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Optional

import click
from rich.console import Console

err = Console(stderr=True)
out = Console()

PBOM_PROFILE = "build-process"
SPEC_VERSION = "1.6"
TOOL_NAME = "pbom-emitter"
TOOL_VERSION = "0.1.0"


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def nix_version() -> str:
    return run(["nix", "--version"]).stdout.strip()


def flake_metadata(attr: str) -> Optional[dict]:
    if "#" not in attr:
        return None
    flake_ref = attr.split("#", 1)[0] or "."
    try:
        r = run(["nix", "flake", "metadata", flake_ref, "--json"])
        return json.loads(r.stdout)
    except subprocess.CalledProcessError:
        return None


def sbomnix_cdx(attr: str, buildtime: bool) -> dict:
    with tempfile.TemporaryDirectory() as td:
        out_file = Path(td) / "out.cdx.json"
        cmd = ["sbomnix", attr, f"--cdx={out_file}"]
        if buildtime:
            cmd.append("--buildtime")
        try:
            run(cmd)
        except subprocess.CalledProcessError as e:
            err.print(f"[red]sbomnix failed[/red]\n{e.stderr}")
            sys.exit(1)
        return json.loads(out_file.read_bytes())


def migrate_tools(tools_field) -> dict:
    """CDX 1.5+ shape: {components: [...], services: [...]}.

    sbomnix emits the deprecated array form; convert it.
    """
    if isinstance(tools_field, dict):
        return tools_field
    comps = []
    for t in tools_field or []:
        comps.append(
            {
                "type": "application",
                "name": t.get("name", "unknown"),
                "version": t.get("version", ""),
                **({"author": t["vendor"]} if t.get("vendor") else {}),
            }
        )
    return {"components": comps}


@click.command()
@click.argument("attr")
@click.option(
    "-o",
    "--output",
    type=click.Path(path_type=Path, dir_okay=False),
    required=True,
    help="Output path for the PBOM (.cdx.json)",
)
@click.option(
    "--buildtime-cdx",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="Pre-built sbomnix --buildtime CDX (skip re-running sbomnix)",
)
@click.option(
    "--runtime-cdx",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="Pre-built sbomnix (runtime) CDX (skip re-running sbomnix)",
)
@click.version_option(version=TOOL_VERSION, prog_name=TOOL_NAME)
def main(
    attr: str,
    output: Path,
    buildtime_cdx: Optional[Path],
    runtime_cdx: Optional[Path],
) -> None:
    if runtime_cdx:
        err.print(f"[cyan]→[/cyan] runtime closure from [bold]{runtime_cdx}[/bold]")
        rt = json.loads(runtime_cdx.read_bytes())
    else:
        err.print(f"[cyan]→[/cyan] sbomnix runtime closure of [bold]{attr}[/bold]")
        rt = sbomnix_cdx(attr, buildtime=False)
    if buildtime_cdx:
        err.print(f"[cyan]→[/cyan] buildtime closure from [bold]{buildtime_cdx}[/bold]")
        bt = json.loads(buildtime_cdx.read_bytes())
    else:
        err.print(f"[cyan]→[/cyan] sbomnix buildtime closure of [bold]{attr}[/bold]")
        bt = sbomnix_cdx(attr, buildtime=True)

    # Tag scope by *content identity*, not by bom-ref. sbomnix uses the
    # input-addressed .drv path as bom-ref, and that path is not stable
    # between consecutive sbomnix invocations (Nix "equivalent derivations":
    # same output, different .drv text). Matching on PURL or output_path
    # makes the PBOM reproducible whenever the underlying build is.
    def content_key(c: dict) -> str:
        if c.get("purl"):
            return c["purl"]
        for p in c.get("properties") or []:
            if p.get("name") == "nix:output_path":
                return p["value"]
        return f"{c.get('name','?')}@{c.get('version','')}"

    runtime_keys: set[str] = {content_key(c) for c in rt.get("components", [])}
    rt_root = rt.get("metadata", {}).get("component", {})
    if rt_root:
        runtime_keys.add(content_key(rt_root))

    components = bt.get("components", [])
    for c in components:
        c["scope"] = "required" if content_key(c) in runtime_keys else "excluded"

    target = dict(bt["metadata"]["component"])
    drv = target["bom-ref"]

    err.print("[cyan]→[/cyan] gathering build identity (nix version, flake lock)")
    nixv = nix_version()
    fmeta = flake_metadata(attr)

    props = [
        {"name": "pbom:profile", "value": PBOM_PROFILE},
        {"name": "nix:version", "value": nixv},
        {"name": "nix:topLevelDrv", "value": drv},
    ]
    if fmeta:
        locked = fmeta.get("locked") or {}
        if locked.get("rev"):
            props.append({"name": "nix:flakeLockedRev", "value": locked["rev"]})
        if locked.get("narHash"):
            props.append({"name": "nix:flakeLockedNarHash", "value": locked["narHash"]})
        if fmeta.get("originalUrl"):
            props.append({"name": "nix:flakeRef", "value": fmeta["originalUrl"]})
        if fmeta.get("resolvedUrl"):
            props.append({"name": "nix:flakeResolvedUrl", "value": fmeta["resolvedUrl"]})

    target.setdefault("properties", [])
    target["properties"].append({"name": "pbom:role", "value": "subject"})

    upstream_tools = bt.get("metadata", {}).get("tools", [])
    tools_block = migrate_tools(upstream_tools)
    tools_block.setdefault("components", []).insert(
        0,
        {"type": "application", "name": TOOL_NAME, "version": TOOL_VERSION},
    )

    pbom = {
        "bomFormat": "CycloneDX",
        "specVersion": SPEC_VERSION,
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "tools": tools_block,
            "component": target,
            "properties": props,
        },
        "components": components,
        "dependencies": bt.get("dependencies", []),
        "formulation": [
            {
                "bom-ref": "formula-1",
                "workflows": [
                    {
                        "bom-ref": "workflow-1",
                        "uid": drv,
                        "name": f"nix build {attr}",
                        "description": (
                            "Top-level Nix derivation; the build process "
                            "producing the subject component. Every component "
                            "in this BOM is an input to this workflow."
                        ),
                        "taskTypes": ["build"],
                        "outputs": [{"resource": {"ref": drv}}],
                    }
                ],
            }
        ],
    }

    output.write_text(json.dumps(pbom, indent=2))

    n_req = sum(1 for c in components if c["scope"] == "required")
    n_exc = sum(1 for c in components if c["scope"] == "excluded")
    err.print(f"[green]✓[/green] PBOM written to [bold]{output}[/bold]")
    err.print(
        f"  components: {len(components)} total · "
        f"[green]{n_req} required[/green] (also in runtime) · "
        f"[yellow]{n_exc} excluded[/yellow] (build-only — the PBOM-only set)"
    )


if __name__ == "__main__":
    main()
