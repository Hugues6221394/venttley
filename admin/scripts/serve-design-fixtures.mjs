// Local-only visual review of sanitized fixtures produced by profile-console.
// No authentication, database clients, member data, or arbitrary file serving.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("..", import.meta.url));
const pages = new Set(["synthetic-shell.html", "synthetic-page-search.html", "synthetic-mobile-navigation.html"]);
const assets = new Set(["cutout-4-2ee7a58500c2.png", "cutout-28-36a4f64d61ee.png", "cutout-20-43ca88ea32cb.png", "cutout-27-1c8fd16dd3f1.png", "cutout-47-f7ff1061d285.png"]);
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, "http://127.0.0.1").pathname;
  const page = pathname.slice(1);
  const asset = pathname.startsWith("/design/operator-shell/") ? pathname.slice(23) : "";
  if (request.method !== "GET" || (!pages.has(page) && !assets.has(asset))) {
    response.writeHead(404); response.end(); return;
  }
  try {
    const file = pages.has(page) ? resolve(root, ".artifacts/operator-shell-v2", page) : resolve(root, "public/design/operator-shell", asset);
    const content = await readFile(file);
    response.writeHead(200, { "Content-Type": pages.has(page) ? "text/html; charset=utf-8" : "image/png",
      "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'nonce-fixture'; font-src 'self'; base-uri 'none'; form-action 'none'" });
    // This fixed script only restores native modal presentation. It is not
    // copied from the authenticated app, and cannot issue data requests.
    response.end(pages.has(page) ? content.toString().replace("</body>", "<script nonce=\"fixture\">document.querySelectorAll('dialog[open]').forEach(d=>{d.removeAttribute('open');d.showModal()})</script></body>") : content);
  } catch { response.writeHead(404); response.end(); }
});
server.listen(3108, "127.0.0.1", () => console.log("Synthetic visual review at http://127.0.0.1:3108/synthetic-shell.html"));
