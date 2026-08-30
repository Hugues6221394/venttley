import { looksLikeSupportedImage } from "./image_magic.ts";
import { isOwnedStoragePath, ownedPathFromPublicUrl } from "./ownership.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
  }
}

Deno.test("media paths are bound to the authenticated owner", () => {
  assertEquals(isOwnedStoragePath("user-1/image.jpg", "user-1"), true);
  assertEquals(isOwnedStoragePath("user-2/image.jpg", "user-1"), false);
  assertEquals(isOwnedStoragePath("user-1/folder/image.jpg", "user-1"), false);
  assertEquals(
    isOwnedStoragePath("user-1/../user-2/image.jpg", "user-1"),
    false,
  );
});

Deno.test("image magic bytes reject a renamed executable", () => {
  const jpeg = new Uint8Array([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]);
  const exe = new Uint8Array([0x4D, 0x5A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  assertEquals(looksLikeSupportedImage(jpeg), true);
  assertEquals(looksLikeSupportedImage(exe), false);
});

Deno.test("only this project's canonical public media URL is accepted", () => {
  const project = "https://project.supabase.co";
  assertEquals(
    ownedPathFromPublicUrl(
      `${project}/storage/v1/object/public/whispers-media/user-1/bg.jpg`,
      project,
      "whispers-media",
      "user-1",
    ),
    "user-1/bg.jpg",
  );
  assertEquals(
    ownedPathFromPublicUrl(
      "https://attacker.invalid/storage/v1/object/public/whispers-media/user-1/bg.jpg",
      project,
      "whispers-media",
      "user-1",
    ),
    null,
  );
  assertEquals(
    ownedPathFromPublicUrl(
      `${project}/storage/v1/object/public/whispers-media/user-2/bg.jpg`,
      project,
      "whispers-media",
      "user-1",
    ),
    null,
  );
});
