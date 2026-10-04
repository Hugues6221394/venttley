import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

// Real authenticated API + UI mutations, never against production. The caller
// validates loopback and supplies only its generated disposable actor.
export async function checkWorkflowCommands({page,visit,sql,userId,auth}) {
 const member=randomUUID(),caseId=randomUUID(),appealCase=randomUUID(),appeal=randomUUID(),post=randomUUID();
 try {
  sql(`BEGIN; SET LOCAL session_replication_role=replica;
   INSERT INTO auth.users(id) VALUES('${member}');
   INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,user_role,account_status,birth_year,display_name,display_name_normalized,username_normalized)
   VALUES('${member}','wf_${member.slice(0,8)}','x','x','normal','active',1990,'Workflow Fixture','workflow fixture','wf_${member.slice(0,8)}');
   INSERT INTO public.moderation_cases(case_id,target_type,target_id,subject_id,sla_due_at,updated_at)
   VALUES('${caseId}','profile','${member}','${member}','1700-01-01','2000-01-01');
   INSERT INTO public.moderation_cases(case_id,target_type,target_id,subject_id,status,decision,decided_by,decided_at,sla_due_at)
   VALUES('${appealCase}','post','${post}','${member}','resolved','no_action','${member}',now(),'1700-01-01');
   INSERT INTO public.moderation_appeals(appeal_id,case_id,appellant_id,statement,created_at)
   VALUES('${appeal}','${appealCase}','${member}','Synthetic runtime appeal','1700-01-01');
   INSERT INTO public.posts(post_id,author_id,category_name,content,post_mood,crisis_level,created_at)
   VALUES('${post}','${member}','mental_health','Synthetic runtime safety signal','sad','high','1700-01-01');
   COMMIT;`);
  await visit('/moderation');await page.getByRole('button',{name:'Review case',exact:true}).first().click();
  let dialog=page.getByRole('dialog');assert(await dialog.getByText(`Case: ${caseId}`,{exact:true}).count(),'fixture selected');
  let form=dialog.getByRole('form',{name:'Record decision',exact:true});
  const operation=await form.locator('[name=operation_id]').inputValue();
  await form.getByLabel('Decision reason').fill('Synthetic runtime no-action decision');
  await form.getByRole('button',{name:'Record decision',exact:true}).click();
  await form.getByRole('button',{name:'Confirm record decision',exact:true}).click();
  try { await form.locator('.workflow-result').waitFor(); }
  catch { throw Error(`Moderation feedback missing: state=${sql(`SELECT status FROM public.moderation_cases WHERE case_id='${caseId}'`)}; forms=${await form.count()}; dialogs=${await page.locator('dialog[open]').count()}`); }
  assert.match(await form.locator('.workflow-result p').first().innerText(),/Case decision recorded/,'moderation command reports confirmed success');
  assert.equal(sql(`SELECT status FROM public.moderation_cases WHERE case_id='${caseId}'`),'resolved');
  const retry=await auth.rpc('admin_case_command',{p_operation:operation,p_case:caseId,p_expected_updated_at:'2000-01-01T00:00:00Z',p_command:'decision',p_value:'no_action',p_note:'Synthetic runtime no-action decision',p_policy:null});
  assert.equal(retry.error,null,'real API case retry');
  assert.equal(sql(`SELECT count(*) FROM public.moderation_case_events WHERE case_id='${caseId}' AND kind='decided'`),'1');
  await form.getByRole('button',{name:'Refresh current record',exact:true}).click();
  await form.waitFor({state:'detached'});
  assert.equal(await page.locator('dialog[open]').count(),0,'explicit refresh removes resolved queue row only after success was shown');
  await visit('/appeals');await page.getByRole('button',{name:'Review appeal',exact:true}).first().click();
  dialog=page.getByRole('dialog');form=dialog.getByRole('form',{name:'Record outcome',exact:true});
  await form.getByLabel('Member-facing explanation').fill('Synthetic runtime independent review');
  await form.getByRole('button',{name:'Record outcome',exact:true}).click();await form.getByRole('button',{name:'Confirm record outcome',exact:true}).click();
  await form.getByRole('status').filter({hasText:'Appeal outcome recorded'}).waitFor();
  assert.equal(sql(`SELECT status FROM public.moderation_appeals WHERE appeal_id='${appeal}'`),'upheld');
  await visit('/support/cases');await page.getByRole('button',{name:'Create case',exact:true}).click();
  dialog=page.getByRole('dialog',{name:'Create support case',exact:true});
  await dialog.getByRole('combobox',{name:/^Source type/}).selectOption('appeal');
  await dialog.getByText('Link a member or source (optional)',{exact:true}).click();
  await dialog.getByLabel('Find appeal',{exact:true}).fill(`wf_${member.slice(0,8)}`);
  await dialog.getByRole('button',{name:'Search records',exact:true}).click();
  await dialog.getByRole('combobox',{name:/^Linked record/}).locator(`option[value="${appeal}"]`).waitFor({state:'attached'});
  await dialog.getByRole('combobox',{name:/^Linked record/}).selectOption(appeal);
  await dialog.getByRole('button',{name:'Create support case',exact:true}).click();
  await dialog.getByRole('button',{name:'Confirm create support case',exact:true}).click();
  await dialog.getByRole('status').filter({hasText:'Support case created.'}).waitFor();
  const bound=sql(`SELECT support_case_id FROM private.support_cases WHERE created_by='${userId}' AND source_id='${appeal}' AND member_id='${member}'`);
  assert.match(bound,/^[a-f0-9-]{36}$/,'source binding derives the correct member');
  await visit(`/support/cases?source=${bound}`);
  await page.getByRole('region',{name:'Support case history',exact:true}).getByText('opened',{exact:true}).waitFor();
  console.log('PASS real scoped source lookup, bound support creation and persisted case history');
  await visit('/safety');await page.getByRole('button',{name:'View signal',exact:true}).first().click();
  dialog=page.getByRole('dialog');assert(await dialog.getByText('Synthetic runtime safety signal',{exact:true}).count());
  form=dialog.getByRole('form',{name:'Record review',exact:true});await form.getByLabel('Review reason').fill('Synthetic runtime completed review');
  await form.getByRole('button',{name:'Record review',exact:true}).click();await form.getByRole('button',{name:'Confirm record review',exact:true}).click();
  await form.getByRole('status').filter({hasText:'Signal review recorded'}).waitFor();
  assert.equal(sql(`SELECT crisis_level IS NULL FROM public.posts WHERE post_id='${post}'`),'t');
  console.log('PASS real moderation decision/retry, independent appeal and safety review with canonical persisted effects');
 } finally {
  // Exact generated IDs, local transaction only. Retain audit/operation receipts.
  sql(`BEGIN; SET LOCAL session_replication_role=replica;
   DELETE FROM private.support_case_events WHERE support_case_id IN (SELECT support_case_id FROM private.support_cases WHERE created_by='${userId}' AND source_id='${appeal}');
   DELETE FROM private.support_cases WHERE created_by='${userId}' AND source_id='${appeal}';
   DELETE FROM public.notifications WHERE user_id='${member}';
   DELETE FROM public.moderation_case_events WHERE case_id IN ('${caseId}','${appealCase}');
   DELETE FROM public.moderation_appeals WHERE appeal_id='${appeal}';
   DELETE FROM public.moderation_cases WHERE case_id IN ('${caseId}','${appealCase}');
   DELETE FROM public.posts WHERE post_id='${post}';
   DELETE FROM public.users WHERE user_id='${member}'; DELETE FROM auth.users WHERE id='${member}'; COMMIT;`);
 }
}
