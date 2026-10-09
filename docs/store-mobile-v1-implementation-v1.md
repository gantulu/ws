# Store Mobile V1 — Implementation V1

- Repository: gantulu/ws
- Implementation branch: feat/store-mobile-v1-app
- Base: spec/store-mobile-v1
- Status: FRONTEND PROTOTYPE IMPLEMENTED — VERIFY REQUIRED
- App architecture: React + Vite; customer-facing UI and page state are contained in src/App.jsx.
- Routes implemented client-side: /products, /products/:slug, /checkout, /tracking/:orderId.

## Included

- Mobile-first catalog with search and category filters.
- Product detail view with size selection, quantity controls, and cart actions.
- Checkout form with browser validation, shipping/payment selection, and order summary.
- Demo order creation and tracking timeline.
- Empty states, feedback notices, responsive layouts, and reduced-motion support.

## Explicitly not integrated

- Product images, names, prices, sizes, shipping options, and payment methods are illustrative frontend demo data.
- No Supabase client or database reads/writes are present.
- No Duitku payment session is created and no callback is handled.
- Demo order IDs and tracking states are local UI state only; refresh/navigation to an unknown ID cannot retrieve a persisted order.
- Checkout totals are calculated in the browser for UI demonstration only and must never be treated as authoritative payment amounts.
- No authentication or customer data authorization is implemented.
- No database, Edge Function, secret, production configuration, legacy integration, or main branch changes are included.

## Verify requirements

1. Install dependencies and run the production build.
2. Manually test catalog filtering, product detail, cart quantity/removal, checkout validation, demo order flow, and direct route refresh behavior.
3. Check small-screen and desktop layouts.
4. Before backend integration, audit the actual product schema/policies and the current order/payment/tracking contracts. Backend must recalculate totals, authorize order access, verify payment callbacks, and enforce idempotency.
5. Do not call payment or shipping integration complete until sandbox end-to-end tests produce evidence.

## Known caveats

- Initial scaffold uses latest dependency tags. Pin tested versions and commit a lockfile as part of reproducible CI/deployment setup.
- Direct-route fallback must be configured in the eventual hosting platform so routes such as /products/linen-shirt serve the app entry document.
- Remote Unsplash image URLs and Google Fonts require network access.
