#!/usr/bin/env node
//
// The store blockers, checked before a build rather than after a rejection.
//
//   node scripts/check-release-readiness.mjs
//
// WHY THIS EXISTS
//
// App Review and Play Console reject for reasons that are cheap to check and
// expensive to discover: a bundle id that still says "vently", a privacy
// manifest that exists on disk but was never added to the target, a build
// number that has not moved since the last upload, a permission string Apple
// calls too vague. Each costs a review cycle -- days, not minutes -- and they
// are found one at a time, because review stops at the first one.
//
// So they are all asserted here, and the script is loud about which ones it
// cannot check: a green run means "nothing known is wrong", not "this will be
// approved".

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// fileURLToPath, not .pathname: this project lives under a directory with a
// space in it, and .pathname hands back "TECH%20PROJECTS".
const root = fileURLToPath(new URL("..", import.meta.url));
const read = (p) => readFileSync(root + p, "utf8");

let failed = 0;
let warned = 0;

const pass = (m) => console.log(`  ok    ${m}`);
const fail = (m, detail) => {
  console.log(`  FAIL  ${m}`);
  if (detail) console.log(`        ${detail}`);
  failed++;
};
const warn = (m, detail) => {
  console.log(`  warn  ${m}`);
  if (detail) console.log(`        ${detail}`);
  warned++;
};

// ---------------------------------------------------------------------------
// Identity. Permanent once published, so wrong here is wrong forever.
// ---------------------------------------------------------------------------

const EXPECTED_ID = "rw.codafriqa.venttly";

const pbxproj = read("ios/Runner.xcodeproj/project.pbxproj");
const iosIds = [...pbxproj.matchAll(/PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);/g)]
  .map((m) => m[1].trim())
  .filter((v) => !v.endsWith(".RunnerTests"));
const uniqueIosIds = [...new Set(iosIds)];

if (uniqueIosIds.length === 1 && uniqueIosIds[0] === EXPECTED_ID) {
  pass(`iOS bundle id is ${EXPECTED_ID}`);
} else {
  fail(
    "iOS bundle id",
    `expected every configuration to be ${EXPECTED_ID}, found ${JSON.stringify(uniqueIosIds)}`,
  );
}

const gradle = read("android/app/build.gradle");
const androidId = gradle.match(/applicationId\s*=\s*"([^"]+)"/)?.[1];
if (androidId === EXPECTED_ID) {
  pass(`Android applicationId is ${EXPECTED_ID}`);
} else {
  fail("Android applicationId", `expected ${EXPECTED_ID}, found ${androidId}`);
}

// A user-facing name, not a package slug. "vently_app" shipped to a store once
// is a store listing that says vently_app.
const manifest = read("android/app/src/main/AndroidManifest.xml");
const androidLabel = manifest.match(/android:label="([^"]+)"/)?.[1];
if (androidLabel === "Venttly") {
  pass("Android display name is Venttly");
} else {
  fail("Android display name", `expected "Venttly", found "${androidLabel}"`);
}

const infoPlist = read("ios/Runner/Info.plist");
if (/<key>CFBundleDisplayName<\/key>\s*<string>Venttly<\/string>/.test(infoPlist)) {
  pass("iOS display name is Venttly");
} else {
  fail("iOS display name", 'CFBundleDisplayName should be "Venttly"');
}

// ---------------------------------------------------------------------------
// Version. Play refuses a versionCode it has already seen; App Store Connect
// refuses a build number it has already seen. Both are silent until upload.
// ---------------------------------------------------------------------------

const pubspec = read("pubspec.yaml");
const version = pubspec.match(/^version:\s*(\S+)/m)?.[1];
const [semver, build] = (version ?? "").split("+");
if (/^\d+\.\d+\.\d+$/.test(semver ?? "") && /^\d+$/.test(build ?? "")) {
  pass(`version ${semver} (build ${build})`);
  if (build === "1") {
    warn(
      "build number is still 1",
      "fine for a first upload; every later one must increment or the store rejects it",
    );
  }
} else {
  fail("pubspec version", `expected <x.y.z>+<int>, found "${version}"`);
}

// ---------------------------------------------------------------------------
// Apple's privacy manifest. Present on disk is not enough -- it has to be in
// the target's Resources phase or it never reaches the bundle.
// ---------------------------------------------------------------------------

if (existsSync(root + "ios/Runner/PrivacyInfo.xcprivacy")) {
  pass("ios/Runner/PrivacyInfo.xcprivacy exists");
  if (/PrivacyInfo\.xcprivacy in Resources/.test(pbxproj)) {
    pass("privacy manifest is in the Runner Resources build phase");
  } else {
    fail(
      "privacy manifest is not in the build",
      "the file exists but no PBXBuildFile references it, so it will not ship",
    );
  }
} else {
  fail("ios/Runner/PrivacyInfo.xcprivacy is missing", "App Store rejects without one");
}

// ---------------------------------------------------------------------------
// Permission strings. Apple rejects boilerplate; each must say what the app
// does with the permission, in a sentence a person would understand.
// ---------------------------------------------------------------------------

for (const key of [
  "NSCameraUsageDescription",
  "NSMicrophoneUsageDescription",
  "NSPhotoLibraryUsageDescription",
]) {
  const value = infoPlist.match(
    new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`),
  )?.[1];
  if (!value) {
    fail(`${key} is missing`);
  } else if (value.length < 30 || !/venttly/i.test(value)) {
    warn(`${key} may be too vague`, `"${value}"`);
  } else {
    pass(`${key} explains itself`);
  }
}

// ---------------------------------------------------------------------------
// Firebase. Push cannot work without these, and their absence is silent:
// the Gradle plugin is applied conditionally, so the build simply succeeds
// without messaging.
// ---------------------------------------------------------------------------

const androidFirebase = existsSync(root + "android/app/google-services.json");
const iosFirebase = existsSync(root + "ios/Runner/GoogleService-Info.plist");

if (androidFirebase) {
  const cfg = JSON.parse(read("android/app/google-services.json"));
  const pkgs = (cfg.client ?? []).map(
    (c) => c.client_info?.android_client_info?.package_name,
  );
  if (pkgs.includes(EXPECTED_ID)) {
    pass(`google-services.json registered for ${EXPECTED_ID}`);
  } else {
    fail(
      "google-services.json is for the wrong package",
      `contains ${JSON.stringify(pkgs)}, expected ${EXPECTED_ID}`,
    );
  }
} else {
  fail("android/app/google-services.json is missing", "Android push will not work");
}

if (iosFirebase) {
  pass("ios/Runner/GoogleService-Info.plist exists");
  // Same trap as the privacy manifest, and it caught this one too: the file sat
  // in ios/Runner for a day without being in the target, so Firebase would have
  // failed to initialise at runtime with the config apparently right there.
  if (/GoogleService-Info\.plist in Resources/.test(pbxproj)) {
    pass("GoogleService-Info.plist is in the Runner Resources build phase");
  } else {
    fail(
      "GoogleService-Info.plist is not in the build",
      "the file exists but no PBXBuildFile references it, so Firebase will not initialise on iOS",
    );
  }
} else {
  warn(
    "ios/Runner/GoogleService-Info.plist is missing",
    "iOS push will not work; needs an Apple Developer Program membership first",
  );
}

// ---------------------------------------------------------------------------
// Android signing. The keystore is deliberately not in the repo, so this only
// reports whether a release build is currently possible on this machine.
// ---------------------------------------------------------------------------

if (existsSync(root + "android/key.properties")) {
  const props = read("android/key.properties");
  const missing = ["storeFile", "storePassword", "keyAlias", "keyPassword"].filter(
    (k) => !new RegExp(`^${k}\\s*=\\s*\\S`, "m").test(props),
  );
  if (missing.length) {
    fail("android/key.properties is incomplete", `missing: ${missing.join(", ")}`);
  } else {
    pass("android/key.properties is complete");
  }
} else {
  warn(
    "android/key.properties is missing",
    "a release AAB cannot be signed without it; see scripts/release.sh",
  );
}

// ---------------------------------------------------------------------------
// The tree. `flutter build` packages the working directory, not a commit.
// ---------------------------------------------------------------------------

try {
  const dirty = execFileSync("git", ["status", "--porcelain"], { cwd: root })
    .toString()
    .split("\n")
    .filter((l) => l.trim() && !l.includes("package-lock.json"));
  if (dirty.length) {
    warn(
      `${dirty.length} uncommitted change(s)`,
      "a build ships what is on disk, not what is committed",
    );
  } else {
    pass("working tree is clean");
  }
} catch {
  warn("could not read git status");
}

// ---------------------------------------------------------------------------

console.log("");
console.log("  Not checked here, and still required before submitting:");
console.log("    - App Store Connect privacy answers matching PrivacyInfo.xcprivacy");
console.log("    - age rating, and the 17+ questions a mental-health app attracts");
console.log("    - screenshots, description, support URL, marketing URL");
console.log("    - in-app account deletion reachable by a reviewer (it exists; they must find it)");
console.log("    - a demo account, because the app is pseudonymous and reviewers cannot sign up blind");
console.log("");

if (failed) {
  console.log(`  check:release — ${failed} blocker(s), ${warned} warning(s)`);
  process.exit(1);
}
console.log(`  check:release — no blockers, ${warned} warning(s)`);
