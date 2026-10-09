# ASRI Store Mobile V1 — `gantulu/ws`

Repository ini sekarang menampung frontend toko online mobile-only dan tetap mempertahankan ruang dokumentasi remediation Duitku V1.2. Implementasi Store Mobile V1 dikerjakan pada branch fitur; branch `main` tidak diubah.

## Status implementasi

- Frontend: React + Vite.
- Komponen dan alur UI utama: `src/App.jsx`.
- Styling berada di file `src/App.jsx`; scaffold entry ada di `src/main.jsx`.
- Halaman: katalog, detail produk, checkout demo, tracking demo.
- Data produk, tarif pengiriman, dan status pesanan saat ini merupakan data simulasi.
- Duitku, Supabase, backend order, dan kurir **belum terhubung**.
- Tidak ada secret atau kredensial yang diperlukan untuk menjalankan prototype.

## Menjalankan aplikasi secara lokal

Persyaratan: Node.js 22 dan npm.

```bash
npm install
npm run dev
```

Untuk memeriksa build produksi:

```bash
npm run build
npm run preview
```

Pengujian browser otomatis:

```bash
npm test
```

## Rute yang tersedia

- `/products` — katalog, pencarian, filter kategori.
- `/products/:slug` — detail produk, ukuran, kuantitas.
- `/checkout` — penerima, pengiriman demo, pilihan pembayaran simulasi.
- `/tracking/:orderId` — status pesanan demo.

Vite menyediakan fallback SPA untuk rute frontend saat dijalankan melalui dev server atau preview.

## Batas keamanan dan integrasi

- Checkout hanya membuat pesanan demo di frontend; tidak memanggil Duitku atau backend.
- Harga dan total dari browser bukan nilai pembayaran otoritatif.
- Jangan gunakan prototype ini untuk menerima pembayaran atau pesanan produksi.
- Jangan mengubah database, Edge Function, secret, atau konfigurasi produksi sebagai bagian dari pekerjaan frontend ini.
- Sebelum integrasi, audit schema dan access policy produk, kontrak pembuatan order, kontrak Duitku sandbox, signature callback, idempotency, serta otorisasi tracking.
- Pertahankan tabel legacy sampai konsumen dan rencana migrasinya dipetakan.

## Dokumentasi yang dipertahankan

- [Store Mobile V1 specification](docs/store-mobile-v1.md)
- [Repository audit V1](docs/repository-audit-v1.md)
- [Implementation and verification log](docs/store-mobile-v1-implementation-v1.md)
- [Store backend contract audit V1](docs/store-backend-contract-audit-v1.md)

README sebelumnya merujuk ke `docs/duitku-v1.2-remediation.md`, tetapi file tersebut tidak ada pada tree yang diaudit. Konten remediasi tidak dibuat ulang tanpa sumber yang disetujui.

## Ruang kerja remediasi Duitku V1.2

Repository ini juga digunakan untuk rancangan keamanan Supabase, integritas pembayaran, idempotency callback, hardening autentikasi custom tanpa Supabase Auth, dan perencanaan sandbox end-to-end. Perubahan backend tetap membutuhkan audit kontrak dan persetujuan tersendiri.
