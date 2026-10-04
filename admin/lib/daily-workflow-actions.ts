'use server';

import { rpc } from './audit';
import { enumOf, optStr, optUuid, reqStr, uuid } from './validate';
import { runWorkflow } from './workflow-actions';
import { supportPriorities, supportStates } from './workflow-model';
import { createSsrClient } from './supabase/server';
import { activeStaffRole } from './staff';
import { workflowUIEnabled, type StaffOption } from './workflows';

const MODERATORS=['super_admin','admin','moderator'];
const SUPPORT=['super_admin','admin','support'];

export async function saveSupportWorkflow(fd:FormData) {
  return runWorkflow(SUPPORT,()=>rpc('admin_update_support_case_checked',{
    p_operation:uuid(fd,'operation_id'),p_case:uuid(fd,'case_id'),p_status:enumOf(fd,'status',supportStates),
    p_priority:enumOf(fd,'priority',supportPriorities),p_assignee:optUuid(fd,'assignee_id'),
    p_expected_updated_at:reqStr(fd,'expected_updated_at',40),
  }),'Support case updated. Refresh the queue to see its current position.');
}
export async function createSupportWorkflow(fd:FormData) {
  return runWorkflow(SUPPORT,()=>rpc('admin_create_support_case_bound',{
    p_operation:uuid(fd,'operation_id'),p_source_kind:enumOf(fd,'source_kind',['appeal','verification','privacy','account','recovery','safety','other']),
    p_source_id:optUuid(fd,'source_id'),p_member:optUuid(fd,'member_id'),
    p_category:enumOf(fd,'category',['access','appeal_help','verification_help','privacy_request','recovery_help','safety_followup','technical','other']),
    p_priority:enumOf(fd,'priority',supportPriorities),
  }),'Support case created. Refresh the queue to see it.');
}
export async function findSupportAssignees(query:string):Promise<{items:StaffOption[];error:boolean}> {
  try {
    const db=await createSsrClient();
    const {data:{user}}=await db.auth.getUser();
    if(!user||!await activeStaffRole(db,user.id,SUPPORT))return {items:[],error:true};
    if(!await workflowUIEnabled()||typeof query!=='string'||query.length>50)return {items:[],error:true};
    const data=await rpc<StaffOption[]>('admin_support_assignees',{p_query:query.trim()});
    return {items:data??[],error:false};
  }catch{return {items:[],error:true};}
}
export async function findSupportBindings(kind:string,query:string):Promise<{items:{id:string;member_id:string;label:string;context:string}[];error:boolean}> {
  try {
    const db=await createSsrClient();const {data:{user}}=await db.auth.getUser();
    if(!user||!await activeStaffRole(db,user.id,SUPPORT)||!await workflowUIEnabled()||!['member','appeal','verification'].includes(kind)||typeof query!=='string'||query.trim().length<4||query.length>50)return {items:[],error:true};
    const items=await rpc<{id:string;member_id:string;label:string;context:string}[]>('admin_support_bindings',{p_kind:kind,p_query:query.trim()});
    return {items:items??[],error:false};
  }catch{return {items:[],error:true};}
}
export async function decideAppealWorkflow(fd:FormData) {
  return runWorkflow(MODERATORS,()=>rpc('admin_appeal_command',{
    p_operation:uuid(fd,'operation_id'),
    p_appeal:uuid(fd,'appeal_id'),p_outcome:enumOf(fd,'outcome',['upheld','overturned']),p_note:reqStr(fd,'note',1000),
  }),'Appeal outcome recorded. The member-facing explanation is included in the decision.');
}
export async function decideCaseWorkflow(fd:FormData) {
  return runWorkflow(MODERATORS,()=>rpc('admin_case_command',{
    p_operation:uuid(fd,'operation_id'),p_expected_updated_at:reqStr(fd,'expected_updated_at',40),p_command:'decision',
    p_case:uuid(fd,'case_id'),p_value:enumOf(fd,'decision',['no_action','content_removed','user_warned','user_suspended','user_banned','user_shadow_restricted']),
    p_policy:optStr(fd,'policy_code',60),p_note:reqStr(fd,'note',1000),
  }),'Case decision recorded. Refresh the queue to see its current state.');
}
export async function claimCaseWorkflow(fd:FormData) {
  return runWorkflow(MODERATORS,()=>rpc('admin_case_command',{
    p_operation:uuid(fd,'operation_id'),p_expected_updated_at:reqStr(fd,'expected_updated_at',40),p_command:'claim',p_case:uuid(fd,'case_id'),
  }),'Case assigned to you. Refresh to verify current ownership.');
}
export async function setCaseWorkflow(fd:FormData) {
  return runWorkflow(MODERATORS,()=>rpc('admin_case_command',{
    p_operation:uuid(fd,'operation_id'),p_expected_updated_at:reqStr(fd,'expected_updated_at',40),p_command:'status',
    p_case:uuid(fd,'case_id'),p_value:enumOf(fd,'status',['in_review','awaiting_second_review','escalated']),p_note:reqStr(fd,'note',500),
  }),'Case workflow updated. Escalation records an internal state; it does not contact an external responder.');
}
export async function reviewSafetyWorkflow(fd:FormData) {
  return runWorkflow(MODERATORS,()=>{
    const kind=enumOf(fd,'kind',['report','post','whisper','tribe_message','chat_message']);
    const id=uuid(fd,'ref_id'),reason=reqStr(fd,'note',500);
    return rpc('admin_safety_command',{p_operation:uuid(fd,'operation_id'),p_kind:kind,p_target:id,p_note:reason});
  },'Signal review recorded. This does not mean emergency help was dispatched.');
}
