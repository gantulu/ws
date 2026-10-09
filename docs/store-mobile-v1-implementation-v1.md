# Store Mobile V1 — Implementation V1

- Repository: `gantulu/ws`
- Implementation branch: `feat/store-mobile-v1-app`
- Base specification branch: `spec/store-mobile-v1`
- Status: **FRONTEND BUILD AND BROWSER SMOKE TESTS VERIFIED — BACKEND INTEGRATION BLOCKED**
- Architecture: React + Vite; the main customer-facing UI and styles are in `src/App.jsx`.
- Routes: `/products`, `/products/:slug`, `/checkout`, `/tracking/:orderId`.

## Included

- Mobile-first catalog, search, category filters, and empty states.
- Product details, size selection, quantity controls, and local cart.
- Checkout fields with native browser validation and demo shipping/payment choices.
- Demo order creation, localStorage-backed demo tracking, and browser refresh behavior.
- Responsive mobile/desktop layouts and reduced-motion support.

## Verification evidence

- Workflow: [Verify Store Mobile V1 run 46](https://github.com/gantulu/ws/actions/runs/37896212476)
- Tested revision: `ae3f19da7f4d843dbb972023278b3dedc1876d4d`
- Production build: **passed**.
- Playwright browser tests: **6 passed** across Chromium mobile (Pixel 7 viewport profile) and desktop.
- Covered behavior: catalog search/category filter, product selection/quantity, checkout required-field validation, demo order/tracking, tracking persistence after refresh, and unknown-route recovery.
- A prior run caught a missing `@vitejs/plugin-react` dependency and a test locator using the wrong accessible label; both were corrected before the successful run.
- The test run is a browser smoke test, not a full accessibility audit, visual regression comparison, or production hosting test.

## Explicitly not integrated

- Product records, images, prices, stock, shipping costs, and payment choices are illustrative demo data.
- No Supabase client or database reads/writes are present in the frontend.
- No real order, Duitku payment session, callback, or shipment is created.
- Demo order state is stored in browser localStorage; it is not a backend record and must not be treated as proof of payment.
- Browser-calculated totals are for display only and are not authoritative payment amounts.
- No customer authentication or server-side order authorization is implemented.
- No database, Edge Function, secret, production configuration, or legacy payment function was changed.

## Backend audit

See [Store Backend Contract Audit V1](store-backend-contract-audit-v1.md). Integration remains blocked because the live product table is empty, the current payment-create route requires a pre-existing draft order, the current identity contract uses direct password comparison, and the payment/tracking schema does not yet cover normalized order items and shipment state. The callback upsert conflict target also needs controlled sandbox verification.

## Known caveats before deployment

- `package.json` currently uses `latest` tags and no lockfile is committed. Pin dependency versions and commit a lockfile before release.
- Configure SPA fallback on the final hosting platform for direct routes such as `/products/linen-shirt`.
- Remote Unsplash images and Google Fonts require network access.
- Do not enable real checkout until backend contract design is approved, sandbox E2E tests pass, and production deployment is separately authorized.
