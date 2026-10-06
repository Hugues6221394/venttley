// Execute the real work-queue model with synthetic rows. No browser or DB.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";

const source = await readFile(new URL("../lib/work-queue.ts", import.meta.url), "utf8");
const url = `data:text/javascript;base64,${Buffer.from(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
}).outputText).toString("base64")}`;
const q = await import(url);

const now = Date.parse("2026-10-06T12:00:00Z");
const hoursAgo = h => new Date(now - h * 3_600_000).toISOString();
const me = { userId: "00000000-0000-0000-0000-0000000000aa", pseudonym: "care_me" };

const cases = q.fromCases([
  { case_id: "c1", target_type: "post", subject_pseudonym: "a", status: "open", severity: "normal", assignee_id: null, assignee_pseudonym: null, report_count: 1, sla_due_at: hoursAgo(-4), sla_breached: false, opened_at: hoursAgo(2) },
  { case_id: "c2", target_type: "dm_message", subject_pseudonym: "b", status: "in_review", severity: "critical", assignee_id: me.userId, assignee_pseudonym: "care_me", report_count: 3, sla_due_at: hoursAgo(-1), sla_breached: false, opened_at: hoursAgo(1) },
  { case_id: "c3", target_type: "comment", subject_pseudonym: "c", status: "open", severity: "low", assignee_id: null, assignee_pseudonym: null, report_count: 2, sla_due_at: hoursAgo(1), sla_breached: true, opened_at: hoursAgo(30) },
  { case_id: "c4", target_type: "post", subject_pseudonym: "d", status: "resolved", severity: "high", assignee_id: null, assignee_pseudonym: null, report_count: 1, sla_due_at: null, sla_breached: false, opened_at: hoursAgo(3) },
]);
assert.equal(cases.length, 3, "resolved cases are not open work");
assert.equal(cases.find(c => c.id === "c2").title, "dm message · 3 reports");

const appeals = q.fromAppeals([
  { appeal_id: "a1", subject_kind: "case", appellant_pseudonym: "e", status: "open", original_decision: "content_removed", reviewable_by_me: false, created_at: hoursAgo(50) },
  { appeal_id: "a2", subject_kind: "case", appellant_pseudonym: "f", status: "upheld", original_decision: null, reviewable_by_me: true, created_at: hoursAgo(5) },
]);
assert.deepEqual(appeals.map(a => a.id), ["a1"]);
assert.match(appeals[0].status, /another reviewer/);

const verification = q.fromVerification([
  { request_id: "v1", pseudonym: "g h", status: "more_info", category: "creator", claimed_by_pseudonym: "care_me", created_at: hoursAgo(10) },
  { request_id: "v2", pseudonym: "i", status: "approved", category: null, claimed_by_pseudonym: null, created_at: hoursAgo(10) },
]);
assert.deepEqual(verification.map(v => v.id), ["v1"]);
assert.equal(verification[0].href, "/verification?q=g%20h", "pseudonym is URL-encoded");

const support = q.fromSupport([
  { support_case_id: "s1", category: "access", priority: "high", status: "assigned", assignee_id: "other", assignee_name: "care_other", sla_due_at: hoursAgo(2), created_at: hoursAgo(20) },
  { support_case_id: "s2", category: "other", priority: "bogus", status: "closed", assignee_id: null, assignee_name: null, sla_due_at: null, created_at: hoursAgo(1) },
], now);
assert.deepEqual(support.map(s => s.id), ["s1"]);
assert.equal(support[0].href, "/support/cases/s1", "support opens its conversation");
const replied = q.fromSupport([{ support_case_id: "s3", category: "technical", priority: "normal", status: "assigned", assignee_id: null, assignee_name: null, sla_due_at: null, created_at: hoursAgo(1), subject: "App will not load", last_message_by: "member" }], Date.now());
assert.equal(replied[0].title, "App will not load", "a conversation is titled by its subject");
assert.equal(replied[0].status, "awaiting reply", "a member waiting on staff is called out");
assert.equal(replied[0].rawStatus, "assigned", "the workflow status is kept for actions");
assert.equal(support[0].overdue, true, "support overdue is derived from its due time");

const all = q.sortWork([...cases, ...appeals, ...verification, ...support]);
assert.deepEqual(all.map(i => i.id), ["s1", "c3", "c2", "c1", "a1", "v1"],
  "overdue first (higher priority first), then priority, then soonest due, then oldest");

assert.deepEqual(q.filterWork(all, "mine", "all", me).map(i => i.id).sort(), ["c2", "v1"],
  "mine matches by id when the source has one, by pseudonym otherwise");
assert.deepEqual(q.filterWork(all, "unassigned", "all", me).map(i => i.id).sort(), ["a1", "c1", "c3"]);
assert.deepEqual(q.filterWork(all, "overdue", "case", me).map(i => i.id), ["c3"]);

const act = id => q.rowActions(all.find(i => i.id === id), me);
assert.deepEqual(act("c1"), { claim: true, release: false, assign: true }, "unassigned case can be claimed or handed to a teammate");
assert.deepEqual(act("c2"), { claim: false, release: true, assign: true }, "my case can be released or handed on");
assert.deepEqual(act("a1"), { claim: false, release: false, assign: false }, "appeals have no assignee to claim");
assert.deepEqual(act("v1"), { claim: false, release: false, assign: false }, "verification in more_info is not claimable");
assert.deepEqual(act("s1"), { claim: false, release: false, assign: true }, "someone else's support case is reassigned, not taken over");
assert.equal(all.find(i => i.id === "c2").href, "/moderation/cases/c2", "cases open their own page");
const pendingVerification = q.fromVerification([{ request_id: "v3", pseudonym: "j", status: "pending", category: null, claimed_by_pseudonym: null, created_at: hoursAgo(1) }])[0];
assert.equal(q.rowActions(pendingVerification, me).claim, true);

assert.equal(q.parseView("mine"), "mine");
assert.equal(q.parseView("<script>"), "all");
assert.equal(q.parseKind("support"), "support");
assert.equal(q.parseKind("constructor"), "all", "prototype keys are not queue kinds");
assert.equal(q.parseKind(undefined), "all");

assert.equal(q.ageLabel(hoursAgo(0.5), now), "30m");
assert.equal(q.ageLabel(hoursAgo(30), now), "30h");
assert.equal(q.ageLabel(hoursAgo(72), now), "3d");
assert.equal(q.dueLabel(hoursAgo(2), now), "2h late");
assert.equal(q.dueLabel(hoursAgo(-4), now), "in 4h");
assert.equal(q.dueLabel(null, now), "—");

console.log("check:work-queue — open-state filters, cross-queue ordering, mine/unassigned/overdue views and safe params passed");
