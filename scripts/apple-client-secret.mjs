#!/usr/bin/env node
//
// The Apple "secret key" Supabase asks for, which Apple never gives you.
//
//   node scripts/apple-client-secret.mjs ~/Downloads/AuthKey_ABC1234DEF.p8
//
// WHY THIS EXISTS
//
// Every other OAuth provider hands you a client secret to paste. Apple hands
// you a .p8 private key and expects you to sign your own: an ES256 JWT whose
// claims identify the team, the key and the Services ID. Supabase's "Secret
// Key (for OAuth)" field wants that JWT, not the .p8 -- pasting the key file
// is the usual first mistake, and it fails at sign-in time rather than at
// paste time.
//
// The JWT also expires. Apple caps its lifetime at 15777000 seconds, a little
// under six months, and rejects anything longer at registration. So this is
// not a one-time setup step: it comes back twice a year, and when it lapses,
// Continue with Apple starts failing with no deploy to blame it on. Hence a
// script rather than a paragraph in a wiki -- re-running it is the fix, and it
// prints the date you will need to.
//
// Node signs ES256 natively (dsaEncoding ieee-p1363 gives the raw r||s pair
// JWS wants, instead of OpenSSL's default DER), so there is nothing to install.

import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { createPrivateKey, createSign } from "node:crypto";

// Venttly's own identifiers, so the common case is one argument. Neither is a
// secret: the Team ID is on every provisioning profile and the Services ID is
// sent to Apple in the clear as the OAuth client_id.
const TEAM_ID = "922424B489";
const SERVICES_ID = "rw.codafriqa.venttly.service";

// Apple's maximum. Asking for more is rejected outright, not clamped.
const MAX_LIFETIME_SECONDS = 15777000;

const die = (message, detail) => {
  console.error(`error: ${message}`);
  if (detail) console.error(`       ${detail}`);
  process.exit(1);
};

const flag = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};

const keyPath = process.argv.slice(2).find((a) => !a.startsWith("--") && !isFlagValue(a));

function isFlagValue(arg) {
  const i = process.argv.indexOf(arg);
  return i > 0 && process.argv[i - 1].startsWith("--");
}

if (!keyPath) {
  die(
    "no .p8 file given",
    "usage: node scripts/apple-client-secret.mjs <AuthKey_XXXXXXXXXX.p8> [--key-id ID] [--team-id ID] [--services-id ID]",
  );
}

let pem;
try {
  pem = readFileSync(keyPath, "utf8");
} catch (e) {
  die(`cannot read ${keyPath}`, e.message);
}

// Apple names the download AuthKey_<KeyID>.p8, and the Key ID is not stored
// anywhere inside the file -- so the filename is the only copy most people
// keep. Honour --key-id when the file has been renamed.
const fromName = basename(keyPath).match(/^AuthKey_([A-Z0-9]{10})\.p8$/i);
const keyId = flag("key-id") ?? fromName?.[1];
if (!keyId) {
  die(
    "cannot determine the Key ID",
    `"${basename(keyPath)}" is not named AuthKey_<KeyID>.p8 -- pass --key-id, it is on the key's page in the Apple Developer portal`,
  );
}

const teamId = flag("team-id") ?? TEAM_ID;
const servicesId = flag("services-id") ?? SERVICES_ID;

let key;
try {
  key = createPrivateKey(pem);
} catch (e) {
  die(`${basename(keyPath)} is not a readable private key`, e.message);
}
// A .p8 that is not P-256 is the wrong key -- most often the APNs key, which
// looks identical on disk and is downloaded during the same sitting.
if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
  die(
    `${basename(keyPath)} is not an ES256 (P-256) key`,
    `found ${key.asymmetricKeyType ?? "unknown"}/${key.asymmetricKeyDetails?.namedCurve ?? "unknown"} -- check you downloaded the Sign in with Apple key, not the APNs one`,
  );
}

const b64url = (input) => Buffer.from(input).toString("base64url");

const issuedAt = Math.floor(Date.now() / 1000);
const expiresAt = issuedAt + MAX_LIFETIME_SECONDS;

const signingInput = [
  b64url(JSON.stringify({ alg: "ES256", kid: keyId })),
  b64url(
    JSON.stringify({
      iss: teamId,
      iat: issuedAt,
      exp: expiresAt,
      aud: "https://appleid.apple.com",
      sub: servicesId,
    }),
  ),
].join(".");

// ieee-p1363, not the DER default: JWS wants the raw 64-byte r||s pair, and a
// DER signature here produces a token Apple rejects as malformed.
const signature = createSign("SHA256")
  .update(signingInput)
  .sign({ key, dsaEncoding: "ieee-p1363" });

const token = `${signingInput}.${b64url(signature)}`;

console.error(`  key id       ${keyId}`);
console.error(`  team id      ${teamId}`);
console.error(`  services id  ${servicesId}`);
console.error(`  expires      ${new Date(expiresAt * 1000).toISOString().slice(0, 10)}  <- re-run this script before then`);
console.error("");
console.error("  Paste the line below into Supabase -> Authentication -> Providers -> Apple");
console.error("  -> Secret Key (for OAuth).");
console.error("");

// stdout is the token alone, so the whole thing can be piped to pbcopy.
console.log(token);
