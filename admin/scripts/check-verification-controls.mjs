import assert from 'node:assert/strict';
import {readVerificationControls} from './verification-controls.mjs';
const tables=['private.access_review_control','private.promotion_control','private.broadcast_approval_control','private.staff_invitation_control'];
const inbox={enabled:false,moderation_events_enabled:false,delivery_retention_enabled:false,job_events_enabled:false,report_events_enabled:false,governance_events_enabled:false};
let installed=false,extra={},bad=null;
function sql(query) {
 assert(query.startsWith('SELECT '),'probe must never mutate');
 if(query.startsWith('SELECT to_regclass'))return installed?'t':'f';
 if(query.endsWith('FROM private.staff_inbox_control c'))return bad??JSON.stringify([{...inbox,...extra.inbox}]);
 if(query.endsWith('FROM private.incident_control'))return JSON.stringify([{enabled:false,notifications_enabled:false,...extra.incidents}]);
 const table=tables.find(name=>query.endsWith(`FROM ${name} c`));assert(table,'unrecognized probe');
 return JSON.stringify([{enabled:false,setup_repair_enabled:false,...extra[table]}]);
}
assert(Object.values(readVerificationControls(sql)).every(v=>v===false));
installed=true;
for(const [table,fields] of Object.entries({inbox:Object.keys(inbox),incidents:['enabled','notifications_enabled'],...Object.fromEntries(tables.map(t=>[t,t.endsWith('staff_invitation_control')?['enabled','setup_repair_enabled']:['enabled']]))})) {
 for(const field of fields) {
  extra={[table]:{[field]:true}};assert(Object.values(readVerificationControls(sql)).some(Boolean),`${table}.${field} must refuse fixtures`);
 }
}
extra={};
for(const malformed of ['null','[]','[{},{}]','[{}]',JSON.stringify([{...inbox,enabled:null}]),JSON.stringify([{...inbox,enabled:'false'}])]) {
 bad=malformed;assert.throws(()=>readVerificationControls(sql));
}
bad=null;
assert.throws(()=>readVerificationControls(()=>{throw Error('database unavailable');}));
assert(Object.values(readVerificationControls(sql)).every(v=>v===false));
console.log('PASS local verification guards: all source controls, missing drafts, unknown/malformed states and read-only queries (synthetic)');
