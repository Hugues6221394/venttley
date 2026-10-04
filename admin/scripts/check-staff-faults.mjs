import assert from 'node:assert/strict';
import {staffReadKind,staffFaultResponse,staffFixtureId} from './staff-fault-proxy.mjs';
const url=path=>new URL(path,'http://127.0.0.1:54321');
const control={mode:'normal',synthetic:true,calls:{directory:0,protection:0,auth:0}};
for(const path of ['/auth/v1/user','/auth/v1/token','/auth/v1/factors','/rest/v1/rpc/is_staff','/rest/v1/users?select=user_role','/rest/v1/users?select=user_id&user_role=eq.normal&limit=2']) {
 assert.equal(staffReadKind(url(path)),null,'authentication and current-role requests are never intercepted');
 assert.equal(staffFaultResponse(url(path),control),undefined);
}
const directory=url('/rest/v1/users');
directory.searchParams.set('select','user_id,display_name,anonymous_pseudonym,user_role,account_status,deactivated_at,created_at,last_seen_at');
directory.searchParams.set('limit','26');
directory.searchParams.append('user_role','in.(super_admin,admin,moderator,support,analyst,read_only_auditor)');
directory.searchParams.append('user_role','eq.moderator');
assert.equal(staffReadKind(directory),'directory');
let result=staffFaultResponse(directory,control);
assert.equal(result.data.length,26);assert.equal(result.data.at(-1).user_id,staffFixtureId(26));
directory.searchParams.set('user_id',`gt.${staffFixtureId(25)}`);
result=staffFaultResponse(directory,control);
assert.equal(result.data.length,5);assert.equal(result.data[0].user_id,staffFixtureId(26));
directory.searchParams.set('user_role','eq.analyst');assert.equal(staffFaultResponse(directory,control).data.length,0);
directory.searchParams.set('user_role','eq.moderator');directory.searchParams.set('or','(account_status.neq.active,deactivated_at.not.is.null)');
assert.equal(staffFaultResponse(directory,control).data.length,0);
const protection=url('/rest/v1/users?select=user_id&user_role=eq.super_admin&limit=2');
assert.equal(staffFaultResponse(protection,control).data.length,2);
const auth=url(`/auth/v1/admin/users/${staffFixtureId(1)}`);
assert.equal(staffFaultResponse(auth,control).data.email,'sample@example.invalid');
assert.throws(()=>staffFaultResponse(url('/auth/v1/admin/users/00000000-0000-4000-8000-000000000001'),control),/outside fixture/);
for(const [kind,request] of [['directory',directory],['protection',protection],['auth',auth]]) {
 control.mode=`${kind}-failed`;
 assert.equal(staffFaultResponse(request,control).status,503);
 assert.equal(staffFaultResponse(url('/rest/v1/users?select=user_role'),control),undefined);
}
control.mode='normal';control.synthetic=false;
for(const request of [directory,protection,auth])assert.equal(staffFaultResponse(request,control),undefined,'real read verification forwards unchanged');
console.log('PASS staff fault fixtures: narrow interception, untouched authorization reads, synthetic cursors/filters and fixed failures');
