# ASRI Collection — Store Mobile V1

This branch contains the first runnable frontend prototype for the mobile online store. The locked page specification and audit documents are preserved in docs/.

## Run locally

Requirements: Node.js 22 or a compatible current LTS release, and npm.

```bash
npm install
npm run dev
```

Open the local URL printed by Vite. To verify a production bundle:

```bash
npm run build
npm run preview
```

## Current implementation scope

- React + Vite; the primary UI and client-side page state live in src/App.jsx.
- Product catalog, search/category filters, product detail, local bag, checkout form, and demo tracking routes.
- This is a frontend-only prototype. Product data, shipping costs, checkout totals, order IDs, payment choices, and tracking are demo data/state.
- No Supabase or Duitku requests are made. No real order or payment is created.

## Documents

- [Store Mobile V1 locked specification](docs/store-mobile-v1.md)
- [Initial repository audit](docs/repository-audit-v1.md)
- [Implementation scope and verification notes](docs/store-mobile-v1-implementation-v1.md)

## Original workspace safety boundaries

The repository also retains its original ASRI Collection Duitku V1.2 remediation and sandbox-verification purpose. Do not change production database or Edge Functions from this frontend branch. Do not commit credentials, API keys, tokens, or secret values. Keep Duitku in sandbox until end-to-end tests pass and production is explicitly approved. Preserve legacy tables until their consumers have been mapped.

Note: the original README referenced docs/duitku-v1.2-remediation.md; that file was not present in the repository inventory when the initial audit was performed. The missing remediation content has not been fabricated.
