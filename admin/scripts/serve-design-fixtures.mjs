// Local-only visual review of sanitized fixtures produced by profile-console.
// No authentication, database clients, member data, or arbitrary file serving.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("..", import.meta.url));
const pages = new Set(["synthetic-shell.html", "synthetic-page-search.html", "synthetic-mobile-navigation.html"]);
const inboxPages = new Set(["synthetic-inbox.html", "synthetic-inbox-drawer.html", "synthetic-inbox-mobile.html"]);
const overviewPages = new Set(["design-input.html", "synthetic-overview.html", "synthetic-overview-mobile.html", "synthetic-overview-definitions.html"]);
const attentionPages = new Set(["synthetic-attention.html"]);
const workflowPages = new Set(['synthetic-moderation.html','synthetic-appeals.html','synthetic-safety.html','synthetic-support.html','synthetic-support-detail.html']);
const recoveryPages = new Set(['synthetic-recovery-queue.html','synthetic-recovery-drawer.html','synthetic-recovery-mobile.html']);
const incidentPages = new Set(['design-incident-input.html','synthetic-incidents.html','synthetic-incident-detail.html','synthetic-incident-declare.html']);
const inboxAssets = new Set([1,2,3].map(n => `viewport-1-a-main-notifications-item-${n}-icon.png`));
const assets = new Set(["cutout-4-2ee7a58500c2.png", "cutout-28-36a4f64d61ee.png", "cutout-20-43ca88ea32cb.png", "cutout-27-1c8fd16dd3f1.png", "cutout-47-f7ff1061d285.png"]);
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, "http://127.0.0.1").pathname;
  const page = pathname.slice(1);
  const asset = pathname.startsWith("/design/operator-shell/") ? pathname.slice(23) : "";
  const inboxAsset = pathname.startsWith("/design/inbox/") ? pathname.slice(14) : "";
  const isPage = pages.has(page) || inboxPages.has(page) || overviewPages.has(page) || attentionPages.has(page) || workflowPages.has(page) || recoveryPages.has(page) || incidentPages.has(page);
  if (request.method !== "GET" || (!isPage && !assets.has(asset) && !inboxAssets.has(inboxAsset))) {
    response.writeHead(404); response.end(); return;
  }
  try {
    const file = incidentPages.has(page) ? resolve(root,'.artifacts/incidents-v1',page) : recoveryPages.has(page) ? resolve(root, '.artifacts/batch4-recovery', page) : workflowPages.has(page) ? resolve(root, '.artifacts/workflows-v3', page) : attentionPages.has(page) ? resolve(root, ".artifacts/attention-v2", page) : overviewPages.has(page) ? resolve(root, ".artifacts/overview-v2", page) : inboxPages.has(page) ? resolve(root, ".artifacts/inbox-v1", page) : pages.has(page) ? resolve(root, ".artifacts/operator-shell-v2", page) : inboxAssets.has(inboxAsset) ? resolve(root, "public/design/inbox", inboxAsset) : resolve(root, "public/design/operator-shell", asset);
    const content = await readFile(file);
    response.writeHead(200, { "Content-Type": isPage ? "text/html; charset=utf-8" : "image/png",
      "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'nonce-fixture'; font-src 'self'; base-uri 'none'; form-action 'none'" });
    // This fixed script only restores native modal presentation. It is not
    // copied from the authenticated app, and cannot issue data requests.
    response.end(isPage ? content.toString().replace("</body>", "<script nonce=\"fixture\">document.querySelectorAll('dialog[open]').forEach(d=>{d.removeAttribute('open');d.showModal()})</script></body>") : content);
  } catch { response.writeHead(404); response.end(); }
});
server.listen(Number(process.env.DESIGN_FIXTURE_PORT ?? 3109), "127.0.0.1", () => console.log("Synthetic visual review ready"));
