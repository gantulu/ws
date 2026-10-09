/**
 * Pure Duitku API V2 contract helpers for the Store Backend V2 Edge Function.
 * Uses Web Crypto so the same module works in Node 22 tests and Deno Edge Runtime.
 * No secrets are stored here; callers must supply the server-side API key.
 */

function requiredText(value, name) {
  const text = String(value ?? "");
  if (!text) throw new TypeError(`${name} is required`);
  return text;
}

export function inquirySignatureInput(merchantCode, merchantOrderId, paymentAmount) {
  const code = requiredText(merchantCode, "merchantCode");
  const orderId = requiredText(merchantOrderId, "merchantOrderId");
  const amount = Number(paymentAmount);
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    throw new TypeError("paymentAmount must be a positive safe integer");
  }
  return `${code}${orderId}${amount}`;
}

export function callbackSignatureInput(merchantCode, amountText, merchantOrderId) {
  const code = requiredText(merchantCode, "merchantCode");
  const amount = requiredText(amountText, "amount");
  const orderId = requiredText(merchantOrderId, "merchantOrderId");
  if (!/^\d+$/.test(amount) || !Number.isSafeInteger(Number(amount)) || Number(amount) <= 0) {
    throw new TypeError("callback amount must be a positive integer string");
  }
  return `${code}${amount}${orderId}`;
}

export function transactionStatusSignatureInput(merchantCode, merchantOrderId) {
  return `${requiredText(merchantCode, "merchantCode")}${requiredText(merchantOrderId, "merchantOrderId")}`;
}

export async function hmacSha256Hex(apiKey, message) {
  const secret = requiredText(apiKey, "apiKey");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(String(message)),
  );
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function createInquirySignature(apiKey, merchantCode, merchantOrderId, paymentAmount) {
  return hmacSha256Hex(apiKey, inquirySignatureInput(merchantCode, merchantOrderId, paymentAmount));
}

export async function createCallbackSignature(apiKey, merchantCode, amountText, merchantOrderId) {
  return hmacSha256Hex(apiKey, callbackSignatureInput(merchantCode, amountText, merchantOrderId));
}

export async function createTransactionStatusSignature(apiKey, merchantCode, merchantOrderId) {
  return hmacSha256Hex(apiKey, transactionStatusSignatureInput(merchantCode, merchantOrderId));
}

export function signaturesEqual(received, expected) {
  const left = String(received ?? "").toLowerCase();
  const right = String(expected ?? "").toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(left) || !/^[a-f0-9]{64}$/.test(right) || left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return difference === 0;
}

/** Callback resultCode contract: 00=success, 01=failed; unknown codes are not guessed. */
export function mapDuitkuCallbackResultCode(resultCode) {
  if (String(resultCode) === "00") return "paid";
  if (String(resultCode) === "01") return "failed";
  return "unknown";
}

/** transactionStatus statusCode contract: 00=success, 01=pending, 02=canceled. */
export function mapDuitkuTransactionStatusCode(statusCode) {
  if (String(statusCode) === "00") return "paid";
  if (String(statusCode) === "01") return "pending";
  if (String(statusCode) === "02") return "cancelled";
  return "unknown";
}

/**
 * Decide whether a provider event can safely change a local payment state.
 * Late-paid/contradictory events must be reconciled rather than silently applied.
 */
export function decidePaymentTransition(currentStatus, incomingStatus) {
  const current = String(currentStatus ?? "");
  const incoming = String(incomingStatus ?? "");
  const known = new Set(["draft", "pending", "paid", "failed", "cancelled", "expired", "creation_failed"]);
  const provider = new Set(["paid", "pending", "failed", "cancelled", "expired"]);

  if (!known.has(current) || !provider.has(incoming)) {
    return { action: "reconcile", status: current || null, reason: "unknown_status" };
  }
  if (current === incoming) {
    return { action: "duplicate", status: current, reason: "same_status" };
  }
  if (current === "paid") {
    return { action: "reconcile", status: "paid", reason: "paid_is_terminal" };
  }
  if (["failed", "cancelled", "expired", "creation_failed"].includes(current)) {
    return {
      action: "reconcile",
      status: current,
      reason: incoming === "paid" ? "late_paid_after_terminal_state" : "terminal_state_conflict",
    };
  }
  if (current === "draft") {
    return { action: "reconcile", status: current, reason: "event_before_payment_attempt" };
  }
  return { action: "apply", status: incoming, reason: "valid_transition" };
}
