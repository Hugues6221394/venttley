import {
  rolloutEnabled,
  secretsMatch,
  verifyInternalSecret,
} from "./internal_auth.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("internal secrets reject missing and partial credentials", () => {
  assert(
    secretsMatch("same-secret", "same-secret"),
    "equal secrets must match",
  );
  assert(!secretsMatch("same", "same-secret"), "prefixes must not match");
  assert(
    !secretsMatch("same-secreu", "same-secret"),
    "different bytes must fail",
  );
});

Deno.test("internal request gate fails closed and accepts the configured header", () => {
  const correct = "correct-webhook-secret-32-bytes!!";
  const different = "different-webhook-secret-32-byte!";
  const request = new Request("https://example.invalid", {
    headers: { "x-webhook-secret": correct },
  });
  const missing = verifyInternalSecret(request, {
    envName: "UNUSED",
    headerName: "x-webhook-secret",
    expected: "",
  });
  assert(
    !missing.ok && missing.status === 500,
    "missing config must fail closed",
  );

  const denied = verifyInternalSecret(request, {
    envName: "UNUSED",
    headerName: "x-webhook-secret",
    expected: different,
  });
  assert(
    !denied.ok && denied.status === 401,
    "wrong credential must be denied",
  );

  const allowed = verifyInternalSecret(request, {
    envName: "UNUSED",
    headerName: "x-webhook-secret",
    expected: correct,
  });
  assert(allowed.ok, "matching credential must be accepted");
});

Deno.test("rollout switches are explicit opt-in", () => {
  assert(!rolloutEnabled("UNUSED", ""), "empty switch must be off");
  assert(!rolloutEnabled("UNUSED", "false"), "false switch must be off");
  assert(rolloutEnabled("UNUSED", "on"), "on switch must be enabled");
});
