import { test, expect } from "@playwright/test";

test("catalog search and category filters work", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Hal sederhana/i })).toBeVisible();
  await page.getByRole("button", { name: "Aksesori", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Everyday Canvas Tote" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Kemeja Linen Relaxed" })).toHaveCount(0);

  await page.getByLabel("Cari produk").fill("wallet");
  await expect(page.getByRole("heading", { name: "Minimal Card Wallet" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Everyday Canvas Tote" })).toHaveCount(0);
});

test("product selection, checkout validation, and demo tracking work", async ({ page }) => {
  await page.goto("/products/linen-shirt");
  await expect(page.getByRole("heading", { name: "Kemeja Linen Relaxed" })).toBeVisible();
  await page.getByRole("button", { name: "Tambah jumlah" }).click();
  await expect(page.locator(".quantity span")).toHaveText("2");
  await page.getByRole("button", { name: /Tambah ke bag/ }).click();
  await page.getByRole("button", { name: /Bag \(/ }).first().click();

  await expect(page.getByRole("heading", { name: "Ringkasan pesanan" })).toBeVisible();
  await expect(page.getByText("Qty 2")).toBeVisible();
  await page.getByRole("button", { name: "Buat pesanan demo" }).click();
  expect(await page.getByLabel("Nama lengkap").evaluate((input) => input.validity.valueMissing)).toBe(true);

  await page.getByLabel("Nama lengkap").fill("Pelanggan Demo");
  await page.getByLabel("Nomor WhatsApp").fill("081234567890");
  await page.getByLabel("Alamat lengkap").fill("Jalan Contoh No. 1, Makassar");
  await page.getByRole("button", { name: "Buat pesanan demo" }).click();

  await expect(page.getByRole("heading", { name: "Pesanan tercatat." })).toBeVisible();
  await expect(page.getByText(/Tidak ada pembayaran atau pengiriman yang dibuat/)).toBeVisible();
  await expect(page.getByText("Menunggu pembayaran", { exact: true })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "Pesanan tercatat." })).toBeVisible();
  await expect(page.getByText(/Data pesanan tidak tersedia di sesi ini/)).toBeVisible();
});

test("unknown routes offer a way back to the catalog", async ({ page }) => {
  await page.goto("/route-that-does-not-exist");
  await expect(page.getByRole("heading", { name: "Halaman tidak ditemukan" })).toBeVisible();
  await page.getByRole("button", { name: "Kembali ke koleksi" }).click();
  await expect(page.getByRole("heading", { name: /Temukan favoritmu/ })).toBeVisible();
});
