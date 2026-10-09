import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import {
  callbackSignatureInput,
  createCallbackSignature,
  createInquirySignature,
  createTransactionStatusSignature,
  decidePaymentTransition,
  inquirySignatureInput,
  mapDuitkuCallbackResultCode,
  mapDuitkuTransactionStatusCode,
  signaturesEqual,
  transactionStatusSignatureInput,
} from "../backend/store-v2/duitku-contract.mjs";

const apiKey = "sandbox-test-key-only";

function referenceHmac(input) {
  return createHmac("sha256", apiKey).update(input).digest("hex");
}

test("inquiry signature follows current API V2 concatenation and HMAC-SHA256", async () => {
  const input = inquirySignatureInput("DTEST", "ORDER-123", 15000);
  assert.equal(input, "DTESTORDER-12315000");
  assert.equal(await createInquirySignature(apiKey, "DTEST", "ORDER-123", 15000), referenceHmac(input));
});

test("callback signature preserves the exact provider amount text", async () => {
  const input = callbackSignatureInput("DTEST", "15000", "ORDER-123");
  assert.equal(input, "DTEST15000ORDER-123");
  assert.equal(await createCallbackSignature(apiKey, "DTEST", "15000", "ORDER-123"), referenceHmac(input));
  assert.throws(() => callbackSignatureInput("DTEST", "15.000", "ORDER-123"), /positive integer string/);
});

test("transaction-status signature uses merchant code plus merchant order ID", async () => {
  const input = transactionStatusSignatureInput("DTEST", "ORDER-123");
  assert.equal(input, "DTESTORDER-123");
  assert.equal(await createTransactionStatusSignature(apiKey, "DTEST", "ORDER-123"), referenceHmac(input));
});

test("signature comparison validates hex and compares case-insensitively", () => {
  const valid = "a".repeat(64);
  assert.equal(signaturesEqual(valid, valid.toUpperCase()), true);
  assert.equal(signaturesEqual(valid, "a".repeat(63)), false);
  assert.equal(signaturesEqual("not-a-signature", valid), false);
});

test("callback resultCode and transaction statusCode have distinct mappings", () => {
  assert.equal(mapDuitkuCallbackResultCode("00"), "paid");
  assert.equal(mapDuitkuCallbackResultCode("01"), "failed");
  assert.equal(mapDuitkuCallbackResultCode("02"), "unknown");
  assert.equal(mapDuitkuTransactionStatusCode("00"), "paid");
  assert.equal(mapDuitkuTransactionStatusCode("01"), "pending");
  assert.equal(mapDuitkuTransactionStatusCode("02"), "cancelled");
  assert.equal(mapDuitkuTransactionStatusCode("99"), "unknown");
});

test("duplicate provider status is idempotent", () => {
  assert.deepEqual(decidePaymentTransition("pending", "pending"), {
    action: "duplicate", status: "pending", reason: "same_status",
  });
});

test("paid payment cannot be downgraded by delayed callback", () => {
  assert.deepEqual(decidePaymentTransition("paid", "failed"), {
    action: "reconcile", status: "paid", reason: "paid_is_terminal",
  });
});

test("late paid after a terminal failure requires reconciliation", () => {
  assert.deepEqual(decidePaymentTransition("expired", "paid"), {
    action: "reconcile", status: "expired", reason: "late_paid_after_terminal_state",
  });
});

test("pending payment may transition to paid, failed, cancelled, or expired", () => {
  for (const status of ["paid", "failed", "cancelled", "expired"]) {
    assert.equal(decidePaymentTransition("pending", status).action, "apply");
    assert.equal(decidePaymentTransition("pending", status).status, status);
  }
});

test("unknown provider status is routed to reconciliation rather than guessed", () => {
  assert.equal(decidePaymentTransition("pending", "unknown").action, "reconcile");
  assert.equal(decidePaymentTransition("draft", "paid").action, "reconcile");
});
