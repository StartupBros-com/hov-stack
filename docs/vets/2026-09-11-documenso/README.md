# T1 prototype from the Documenso harness vet (2026-09-11)

> Superseded on 2026-09-12 by `skills-local/sign-it` (the shipped skill, also the HoV marketplace plugin sign-it). Kept as evidence for the vet; do not install or extend.

Evidence attachments for `../2026-09-11-documenso-harness-vet.md`, produced by the `bare-t1` empirical agent. Not installed anywhere; a recommendation, not a landed tool.

- `gen-signature.mjs`: renders a transparent-background signature PNG from an HTML/SVG page with Playwright Chromium (one-time; the operator would instead store a real signature image at a private path).
- `sign.mjs`: stamps a signature PNG plus optional typed name and date onto a PDF page with pdf-lib. Usage is in the file header. Measured: 5 npm packages, 26 MB `node_modules`, 0.17 s per document.
- Cryptographic seal (optional): `uv pip install pyhanko pyhanko-cli`, then `pyhanko sign addsig --field Sig1 pkcs12 --passfile <pass> in.pdf out.pdf cert.p12`; `pdfsig out.pdf` reports "Signature is Valid" and, for a self-signed cert, "Certificate issuer isn't Trusted", the same standing as a self-hosted Documenso seal.
