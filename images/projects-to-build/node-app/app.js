// Node baseline app for the nix-sbom thesis comparison.
// Mirrors the Python/Flask app: same routes, same port.
// `express` is the manual (third-party) dependency; `fetch` is built into Node.
const express = require("express");

const app = express();

app.get("/", (req, res) => {
  res.json({ message: "hello from nix-sbom thesis demo" });
});

app.get("/health", (req, res) => {
  res.json({ ok: true });
});

app.get("/fetch/*", async (req, res) => {
  const url = req.params[0];
  try {
    const r = await fetch(`https://${url}`, { signal: AbortSignal.timeout(5000) });
    const body = await r.arrayBuffer();
    res.json({ status: r.status, bytes: body.byteLength });
  } catch (err) {
    res.status(502).json({ error: String(err) });
  }
});

const host = process.env.HOST || "0.0.0.0";
const port = parseInt(process.env.PORT || "8000", 10);

app.listen(port, host, () => {
  console.log(`listening on http://${host}:${port}`);
});
