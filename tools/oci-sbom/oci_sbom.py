#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Optional

import click
from rich.console import Console
from rich.table import Table

err = Console(stderr=True)
out = Console()




def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_to_blob_path(image_dir: Path, digest: str) -> Path:
    if ":" in digest:
        algo, hex_str = digest.split(":", 1)
    else:
        algo, hex_str = "sha256", digest
    return image_dir / "blobs" / algo / hex_str


def default_annotation_key(media_type: str) -> str:
    if "spdx" in media_type:
        return "org.opencontainers.image.sbom.spdx"
    if "cyclonedx" in media_type:
        return "org.opencontainers.image.sbom.cyclonedx"
    return f"org.opencontainers.image.sbom.{media_type.replace('/', '_')}"


def require_oci_layout(image_dir: Path) -> None:
    if not (image_dir / "oci-layout").exists():
        err.print(f"[red]error[/red]: not an OCI layout: {image_dir}")
        sys.exit(1)


def load_single_manifest(image_dir: Path) -> tuple[dict, dict, dict, str]:
    """Return (index, manifest_descriptor, manifest, manifest_digest)."""
    require_oci_layout(image_dir)
    index = json.loads((image_dir / "index.json").read_bytes())
    manifests = index.get("manifests") or []
    if not manifests:
        err.print("[red]error[/red]: index.json has no manifests")
        sys.exit(1)
    if len(manifests) > 1:
        err.print(
            f"[red]error[/red]: multi-manifest indices not supported (found {len(manifests)})"
        )
        sys.exit(1)
    desc = manifests[0]
    manifest_digest = desc["digest"]
    manifest = json.loads(digest_to_blob_path(image_dir, manifest_digest).read_bytes())
    return index, desc, manifest, manifest_digest


"""Write data as a content-addressed blob, return its sha256 digest hex."""
def write_blob(image_dir: Path, data: bytes) -> str:
    digest = sha256_hex(data)
    blobs_dir = image_dir / "blobs" / "sha256" # path to oci image
    blobs_dir.mkdir(parents=True, exist_ok=True)
    (blobs_dir / digest).write_bytes(data)
    return digest

@click.group()
@click.version_option(version="0.1.0", prog_name="oci-sbom")
def cli() -> None:
    """Attach, list, extract and verify SBOMs on OCI images."""


image_opt = click.option(
    "-i",
    "--image",
    type=click.Path(path_type=Path, exists=True, file_okay=False),
    required=True,
    help="OCI layout directory",
)


"""Attach an SBOM as a blob + manifest annotation."""
@cli.command()
@image_opt
@click.option(
    "-s",
    "--sbom",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    required=True,
    help="SBOM file to attach",
)
@click.option(
    "-t",
    "--media-type",
    required=True,
    help="e.g. application/spdx+json, application/vnd.cyclonedx+json",
)
@click.option(
    "-a",
    "--annotation",
    default=None,
    help="Annotation key (default is derived from --media-type)",
)
def attach(
    image: Path, sbom: Path, media_type: str, annotation: Optional[str]
) -> None:
    sbom_bytes = sbom.read_bytes()
    sbom_digest = write_blob(image, sbom_bytes)
    err.print(
        f"blob [cyan]sha256:{sbom_digest}[/cyan] ({len(sbom_bytes)} bytes) [{media_type}]"
    )

    index, desc, manifest, manifest_digest = load_single_manifest(image)

    key = annotation or default_annotation_key(media_type)
    value = f"sha256:{sbom_digest}"
    annotations = manifest.get("annotations") or {}
    annotations[key] = value
    manifest["annotations"] = annotations
    err.print(f"annotation [green]{key}[/green] = {value}")

    new_manifest_bytes = json.dumps(manifest, separators=(",", ":")).encode()
    new_manifest_digest = write_blob(image, new_manifest_bytes)

    new_desc = dict(desc)
    new_desc["digest"] = f"sha256:{new_manifest_digest}"
    new_desc["size"] = len(new_manifest_bytes)
    index["manifests"] = [new_desc]
    (image / "index.json").write_text(json.dumps(index, indent=2))
    err.print(
        f"manifest {manifest_digest} -> [magenta]sha256:{new_manifest_digest}[/magenta]"
    )


"""List SBOM/PBOM annotations on the image manifest."""
@cli.command(name="list")
@image_opt
def list_cmd(image: Path) -> None:
    _, _, manifest, manifest_digest = load_single_manifest(image)
    table = Table(title=f"manifest {manifest_digest}")
    table.add_column("annotation key", style="green")
    table.add_column("blob digest", style="cyan")
    found = False
    for k, v in (manifest.get("annotations") or {}).items():
        if "sbom" in k or "pbom" in k:
            table.add_row(k, v)
            found = True
    if not found:
        err.print("[yellow]no SBOM/PBOM annotations found[/yellow]")
        return
    out.print(table)


"""Extract an attached SBOM blob by annotation key."""
@cli.command()
@image_opt
@click.option(
    "-k",
    "--annotation",
    required=True,
    help="Annotation key to extract (e.g. org.opencontainers.image.sbom.cyclonedx)",
)
@click.option(
    "-o",
    "--output",
    type=click.Path(path_type=Path, dir_okay=False),
    default="-",
    help="Output file (use '-' for stdout, default)",
)
def extract(image: Path, annotation: str, output: Path) -> None:
    _, _, manifest, _ = load_single_manifest(image)
    annotations = manifest.get("annotations") or {}
    if annotation not in annotations:
        err.print(
            f"[red]error[/red]: annotation '{annotation}' not on manifest"
        )
        sys.exit(1)
    blob_digest = annotations[annotation]
    data = digest_to_blob_path(image, blob_digest).read_bytes()
    if str(output) == "-":
        sys.stdout.buffer.write(data)
    else:
        Path(output).write_bytes(data)
        err.print(f"wrote {output} ({len(data)} bytes)")


"""Recompute every digest in the image and report tampering."""
@cli.command()
@image_opt
def verify(image: Path) -> None:
    require_oci_layout(image)
    index = json.loads((image / "index.json").read_bytes())
    ok = True
    table = Table(title=f"verify {image}")
    table.add_column("kind")
    table.add_column("key / digest")
    table.add_column("status")

    def check(kind: str, label: str, expected_digest: str) -> bool:
        blob_path = digest_to_blob_path(image, expected_digest)
        if not blob_path.exists():
            table.add_row(kind, label, "[red]MISSING[/red]")
            return False
        actual = "sha256:" + sha256_hex(blob_path.read_bytes())
        if actual != expected_digest:
            table.add_row(kind, label, "[red]MISMATCH[/red]")
            return False
        table.add_row(kind, label, "[green]OK[/green]")
        return True

    for desc in index.get("manifests") or []:
        digest = desc["digest"]
        if not check("manifest", digest, digest):
            ok = False
            continue
        manifest = json.loads(digest_to_blob_path(image, digest).read_bytes())
        config = manifest.get("config")
        if config:
            ok &= check("config", config["digest"], config["digest"])
        for layer in manifest.get("layers") or []:
            ok &= check("layer", layer["digest"], layer["digest"])
        for k, v in (manifest.get("annotations") or {}).items():
            if "sbom" in k or "pbom" in k:
                ok &= check("attachment", k, v)

    out.print(table)
    if not ok:
        err.print("[red]verification FAILED[/red]")
        sys.exit(1)
    err.print("[green]verification OK[/green]")


if __name__ == "__main__":
    cli()
