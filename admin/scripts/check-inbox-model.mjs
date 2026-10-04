import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";
const source = await readFile(new URL("../lib/inbox-model.ts", import.meta.url), "utf8");
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const model = await import(`data:text/javascript;base64,${Buffer.from(js).toString("base64")}`);
assert.equal(model.parseInboxQuery(new URLSearchParams("category=unknown")), null);
assert.equal(model.parseInboxQuery(new URLSearchParams("beforeId=bad")), null);
assert.equal(model.parseInboxQuery(new URLSearchParams("filter=urgent&category=support&severity=critical")).filter, "urgent");
assert.equal(model.sourceHref({ kind: "support_assigned", destination: "https://evil.test", source_id: "00000000-0000-4000-8000-000000000001" }), "/support/cases?source=00000000-0000-4000-8000-000000000001");
assert.equal(model.sourceHref({ kind: "support_assigned", source_id: "x?secret" }), null);
assert.equal(model.pollDelay(0), 30000); assert.equal(model.pollDelay(99), 300000);
assert.equal(model.staleTimestamp(null), true);
assert.equal(model.staleTimestamp(new Date(0).toISOString(), 120001), true);
assert.equal(model.staleTimestamp(new Date(1000).toISOString(), 2000), false);
console.log("check:inbox — filter validation, safe destinations, stale timestamps and bounded backoff passed");
const valid = { enabled:true, unread_count:2, unread_more:false, generated_at:new Date().toISOString(), worker_at:null,
  queues:[{key:'moderation',count:12345,measured_at:new Date().toISOString(),stale:false}] };
assert.deepEqual(model.parseAttention(valid),valid);
assert.deepEqual(model.parseAttention({...valid, queues:[{...valid.queues[0],key:'incidents'}]})?.queues[0].key,'incidents');
assert.equal(model.attentionDestination('/incidents',valid,true),'/incidents?filter=active');
for(const count of [-1,NaN,Infinity,1.5,Number.MAX_SAFE_INTEGER+1]) assert.equal(model.parseAttention({...valid,queues:[{...valid.queues[0],count}]}),null);
assert.equal(model.parseAttention({...valid,queues:[...valid.queues,...valid.queues]}),null);
assert.equal(model.parseAttention({...valid,queues:[{...valid.queues[0],key:'private-evidence'}]}),null);
assert.equal(model.parseAttention({...valid,unread_count:100}),null);
assert.deepEqual(model.parseAttention({enabled:false,queues:valid.queues}),{enabled:false});
assert.equal(model.attentionDestination('/moderation',null,true),'/moderation?tab=pending');
assert.equal(model.attentionDestination('/appeals',valid,true),'/appeals?tab=open');
assert.equal(model.attentionDestination('/analytics',valid,true),'/analytics');
assert.equal(model.attentionDestination('/moderation',valid,false),'/moderation');
console.log('check:attention — bounded payloads, queue keys, duplicate keys and exact destinations passed');
for(const kind of ['moderation_assigned','moderation_review_requested']) {
  assert.equal(model.sourceHref({kind,source_id:'00000000-0000-4000-8000-000000000001',destination:'https://evil.test'}),'/moderation/cases/00000000-0000-4000-8000-000000000001');
  assert.equal(model.sourceHref({kind,source_id:'../../evidence'}),null);
}
assert.equal(model.parseInboxQuery(new URLSearchParams('category=moderation')).category,'moderation');
for(const [kind,href] of Object.entries({job_push_attention:'/jobs#push-failures',job_email_attention:'/jobs#email-failures',job_media_attention:'/jobs#media-stalled',impact_report_ready:'/impact/reports/00000000-0000-4000-8000-000000000001'})) {
  assert.equal(model.sourceHref({kind,source_id:'00000000-0000-4000-8000-000000000001',destination:'https://evil.test'}),href);
}
assert.equal(model.parseInboxQuery(new URLSearchParams('category=jobs')).category,'jobs');
assert.equal(model.parseInboxQuery(new URLSearchParams('category=reports')).category,'reports');
assert.equal(model.parseInboxQuery(new URLSearchParams('category=incidents')).category,'incidents');
assert.equal(model.parseInboxQuery(new URLSearchParams('category=governance')).category,'governance');
for(const [kind,href] of Object.entries({access_review_assigned:'/staff/access-reviews?campaign=',access_review_overdue:'/staff/access-reviews?campaign=',promotion_review_requested:'/approvals?source=',promotion_ready:'/approvals?source=',broadcast_review_requested:'/broadcasts?source=',broadcast_ready:'/broadcasts?source='})) {
  assert.equal(model.sourceHref({kind,source_id:'00000000-0000-4000-8000-000000000001',destination:'https://evil.test'}),href+'00000000-0000-4000-8000-000000000001');
  assert.equal(model.sourceHref({kind,source_id:'../../evidence'}),null);
  assert.equal(model.inboxCopy[kind].category,'Governance');
}
for (const kind of ['incident_changed', 'incident_overdue']) {
  assert.equal(model.sourceHref({kind,source_id:'00000000-0000-4000-8000-000000000001',destination:'https://evil.test'}),'/incidents/records/00000000-0000-4000-8000-000000000001');
  assert.equal(model.sourceHref({kind,source_id:'../../evidence'}),null);
}
