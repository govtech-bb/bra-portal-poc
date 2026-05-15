[![Deploy to S3 + CloudFront](https://github.com/govtech-bb/bra-portal-poc/actions/workflows/deploy.yml/badge.svg)](https://github.com/govtech-bb/bra-portal-poc/actions/workflows/deploy.yml)

# BRA portal POC

Prototype for the **Barbados Revenue Authority** online services. A static, click-through demo of the sign-in flow and the Personal Income Tax file-return wizard — no backend, no database, no real taxpayer data.

**Live:** https://d2rlpfp2tbfhma.cloudfront.net/

---

## What's in it

| Flow | Pages |
|---|---|
| Sign in | `index.html`, `sign-in.html`, `sign-in-tamis.html`, `sign-in-trident.html`, `create-account.html` |
| Dashboard | `dashboard.html` |
| File a return | `file-return.html` → 16 step pages (`file-return-about.html`, `file-return-income-types.html`, ...) → `file-return-check.html` → `file-return-confirmation.html` |

The file-return wizard mirrors the live TAMIS 12-page Personal Income Tax flow but rebuilt against the [GovBB design system](https://github.com/govtech-bb/styles) for a modern, accessible UX.

## Stack

- Plain HTML + CSS + vanilla JS — no framework, no build step
- [`@govtech-bb/styles`](https://github.com/govtech-bb/styles) vendored as `assets/govbb.css`
- [Figtree](https://fonts.google.com/specimen/Figtree) self-hosted as woff2 in `assets/fonts/`
- Hosted on S3 + CloudFront (us-east-1)

## Run it locally

Pick whichever you have on hand:

```sh
# any static file server works
python3 -m http.server 8000     # then open http://localhost:8000
# or
npx serve .
# or just open index.html in a browser
```

No environment variables, no dependencies to install.

## Deploy

**Push to `main` — that's it.** GitHub Actions ([`deploy.yml`](./.github/workflows/deploy.yml)) syncs the site to S3, sets cache headers and MIME types per file type, and invalidates CloudFront. Full deploy takes ~20 seconds.

Watch a run: [Actions tab](https://github.com/govtech-bb/bra-portal-poc/actions).

**Manual fallback** (e.g. if Actions is down): `./deploy.sh bra-portal-poc-cc us-east-1` with AWS credentials in your environment. See [`deploy.md`](./deploy.md) for the long-form walkthrough.

**CI/CD setup** (one-time, already done for this repo): see [`.github/workflows/SETUP.md`](./.github/workflows/SETUP.md) for the AWS OIDC + IAM role setup. No long-lived AWS keys live in GitHub — the workflow assumes a role at run time via OIDC federation.

## File structure

```
.
├── index.html, sign-in*.html, create-account.html, dashboard.html
├── file-return*.html              # the 18-page tax return wizard
├── assets/
│   ├── govbb.css                  # design system
│   ├── return-flow.css            # wizard-specific styles
│   ├── flow.js                    # client-side wizard logic
│   ├── fonts/                     # Figtree woff2
│   └── images/                    # GovBB crest, logo
├── deploy.sh                      # manual fallback deploy
├── deploy.md                      # deployment runbook
└── .github/workflows/deploy.yml   # CI/CD pipeline
```

## POC limitations

This is a **prototype**, not a product:

- Not connected to any BRA backend — sign-in always "works", all answers are discarded
- No form persistence between pages yet (next thing to add — small `localStorage` writes per page, replayed on Check Your Answers)
- No clean URLs (`/sign-in.html` not `/sign-in`)
- No custom domain — served from a `d…cloudfront.net` URL
- No 404 page

See [`deploy.md`](./deploy.md#whats-left-to-add-for-a-real-launch) for the path to a real launch.

## License

Internal Government of Barbados project. Not yet licensed for external reuse.
