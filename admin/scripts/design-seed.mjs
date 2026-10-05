// Local-only synthetic data for design screenshots. Refuses any non-loopback
// Supabase target. Every row is fictional and tagged with the `design-` prefix
// so `node scripts/design-seed.mjs --clean` removes exactly what it created.
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(execFileSync("supabase", ["status", "-o", "json"], {
  cwd: resolve(root, ".."), encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
}));
for (const key of ["API_URL", "DB_URL"]) {
  if (!["127.0.0.1", "localhost"].includes(new URL(config[key]).hostname)) {
    throw new Error("Design seed requires local Supabase. Refusing remote target.");
  }
}
const sql = (statement) => execFileSync("psql", [config.DB_URL, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", statement], { encoding: "utf8" });
const service = createClient(config.API_URL, config.SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

async function clean() {
  const ids = sql(`SELECT user_id FROM public.users WHERE anonymous_pseudonym LIKE 'design%'`).split("\n").filter(Boolean);
  sql(`SET session_replication_role = replica; DELETE FROM public.reports WHERE post_id IN (SELECT post_id FROM public.posts WHERE content LIKE '[design]%'); DELETE FROM public.posts WHERE content LIKE '[design]%';`);
  for (const id of ids) await service.auth.admin.deleteUser(id);
  console.log(`Removed ${ids.length} synthetic members and their posts/reports.`);
}

if (process.argv.includes("--clean")) { await clean(); process.exit(0); }

const countries = ["RW", "RW", "RW", "RW", "KE", "KE", "UG", "US", "US", "NG", "TZ", "FR", "GB", "CA", null];
const names = ["quietriver", "softlantern", "northwind", "emberleaf", "paperboat", "stillwater", "moonmoth", "cedarpath",
  "lowtide", "kindfog", "slowbloom", "halfmoon", "seaglass", "duskbird", "warmstone", "openfield", "rainjar", "pinecone",
  "littleowl", "brightsea", "willowcat", "saltlake", "honeybee", "farlight", "greyhaze", "tinyflame", "lakeside", "goldfern",
  "skylark", "mistvale", "coralbay", "nightjar", "amberfox", "riverbend", "snowpea", "starling", "meadowlark", "palmtree"];
const ids = [];
for (const [index, name] of names.entries()) {
  const pseudonym = `design${name}`;
  const existing = sql(`SELECT user_id FROM public.users WHERE anonymous_pseudonym='${pseudonym}'`).trim();
  if (existing) { ids.push(existing); continue; }
  const created = await service.auth.admin.createUser({
    email: `${pseudonym}@example.test`, password: `Local-${crypto.randomUUID()}-Aa1!`, email_confirm: true,
    user_metadata: { pseudonym, avatar_seed: pseudonym, birth_year: "1998", birth_month: "3" },
  });
  if (created.error) throw new Error(`Auth creation failed for synthetic member ${index}`);
  const id = created.data.user.id;
  const exists = sql(`SELECT 1 FROM public.users WHERE user_id='${id}'`).trim();
  if (!exists) {
    sql(`INSERT INTO public.users (user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,birth_year)
      VALUES ('${id}','${pseudonym}','${pseudonym}','design-only','${name}','${name}','${pseudonym}',1998)`);
  }
  ids.push(id);
}
const daysAgo = (i) => (i * 7) % 29;
ids.forEach((id, i) => {
  const country = countries[i % countries.length];
  const status = i === 5 ? "suspended" : i === 11 ? "restricted" : "active";
  sql(`SET session_replication_role = replica; UPDATE public.users SET created_at = now() - interval '${daysAgo(i)} days' - interval '${i} hours',
    home_country = ${country ? `'${country}'` : "NULL"}, karma_points = ${(i * 37) % 420}, account_status='${status}' WHERE user_id='${id}'`);
});

const categories = ["mental_health", "relationships", "vent_zone", "campus_life", "adulting", "healing_corner", "late_night", "family_issues"];
const moods = ["sad", "lonely", "anxious", "hopeful", "healing", "exhausted", "overthinking", "grateful"];
const lines = [
  "Exams start next week and I can't stop overthinking every small thing.",
  "Finally told my sister how I've been feeling. It went better than I expected.",
  "Some days the city feels so loud and I just want a quiet corner.",
  "Grateful for the stranger who replied to my last post. It really helped.",
  "Moving out for the first time and I feel lonely in a way I didn't expect.",
  "Trying to rebuild a routine after a rough month. Small steps.",
  "Does anyone else feel exhausted even after sleeping ten hours?",
  "My friend group drifted apart and I don't know how to start again.",
];
const existingPosts = Number(sql(`SELECT count(*) FROM public.posts WHERE content LIKE '[design]%'`).trim());
if (existingPosts === 0) {
  const values = [];
  for (let i = 0; i < 64; i++) {
    const author = ids[(i * 5) % ids.length];
    const hours = (i * 11) % (24 * 14);
    const crisis = i % 21 === 3 ? "'high'" : i % 17 === 4 ? "'elevated'" : "NULL";
    values.push(`('${author}','f1f1f1f1-0000-4000-8000-000000000001','${categories[i % categories.length]}','[design] ${lines[i % lines.length].replaceAll("'", "''")}','${moods[i % moods.length]}',now() - interval '${hours} hours',${crisis},${(i * 13) % 90},${(i * 3) % 14})`);
  }
  sql(`SET session_replication_role = replica; INSERT INTO public.posts (author_id,tribe_id,category_name,content,post_mood,created_at,crisis_level,likes_count,comments_count) VALUES ${values.join(",")}`);
  const posts = sql(`SELECT post_id FROM public.posts WHERE content LIKE '[design]%' ORDER BY created_at DESC`).split("\n").filter(Boolean);
  const reasons = ["harassment", "spam", "self_harm", "hate", "privacy", "other", "harassment", "spam", "violence", "sexual_content"];
  const reports = [];
  for (let i = 0; i < 34; i++) {
    const post = posts[(i * 3) % posts.length];
    const reporter = ids[(i * 7 + 1) % ids.length];
    const resolved = i % 3 === 0;
    reports.push(`('${post}','${reporter}','${reasons[i % reasons.length]}',${i % 4 === 1 ? "'Synthetic reporter note for design review.'" : "NULL"},now() - interval '${(i * 19) % (24 * 28)} hours',${resolved})`);
  }
  try {
    sql(`INSERT INTO public.reports (post_id,reporter_id,reason,note,created_at,is_resolved) VALUES ${reports.join(",")} ON CONFLICT DO NOTHING`);
  } catch {
    sql(`SET session_replication_role = replica; INSERT INTO public.reports (post_id,reporter_id,reason,note,created_at,is_resolved) VALUES ${reports.join(",")} ON CONFLICT DO NOTHING`);
  }
}
try { sql(`SELECT private.refresh_admin_overview(p) FROM unnest(array['activity','queues','reports','regions']) p`); } catch { console.warn("Overview snapshot refresh failed; v2 panels may show unavailable."); }
console.log(sql(`SELECT (SELECT count(*) FROM public.users) || ' members, ' || (SELECT count(*) FROM public.posts) || ' posts, ' || (SELECT count(*) FROM public.reports) || ' reports'`).trim());
