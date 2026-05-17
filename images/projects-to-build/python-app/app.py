from flask import Flask
import click
import requests

app = Flask(__name__)


@app.route("/")
def index():
    return {"message": "hello from nix-sbom thesis demo"}


@app.route("/health")
def health():
    return {"ok": True}


@app.route("/fetch/<path:url>")
def fetch(url):
    r = requests.get(f"https://{url}", timeout=5)
    return {"status": r.status_code, "bytes": len(r.content)}


@click.command()
@click.option("--host", default="0.0.0.0", help="Bind host")
@click.option("--port", default=8000, type=int, help="Bind port")
def main(host, port):
    app.run(host=host, port=port)


if __name__ == "__main__":
    main()
