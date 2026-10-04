// Fixed, read-only inventory for the disposable local verification runner.
// Missing optional draft tables mean not installed, never evidence of readiness.
const optionalControls = [
  ['private.access_review_control', ['enabled']],
  ['private.promotion_control', ['enabled']],
  ['private.broadcast_approval_control', ['enabled']],
  ['private.staff_invitation_control', ['enabled', 'setup_repair_enabled']],
];
function row(value, fields) {
  const rows=JSON.parse(value);
  if(!Array.isArray(rows)||rows.length!==1||!rows[0]||typeof rows[0]!=='object')throw Error('Verification control inventory is unavailable.');
  const result={};
  for(const field of fields) {
    if(typeof rows[0][field]!=='boolean')throw Error('Verification control state is unknown.');
    result[field]=rows[0][field];
  }
  return result;
}
export function readVerificationControls(sql) {
  const inboxFields=['enabled','moderation_events_enabled','delivery_retention_enabled','job_events_enabled','report_events_enabled','governance_events_enabled'];
  const inbox=row(sql("SELECT json_agg(json_build_object('enabled',c.enabled,'moderation_events_enabled',c.moderation_events_enabled,'delivery_retention_enabled',c.delivery_retention_enabled,'job_events_enabled',c.job_events_enabled,'report_events_enabled',c.report_events_enabled,'governance_events_enabled',COALESCE((to_jsonb(c)->>'governance_events_enabled')::BOOLEAN,false))) FROM private.staff_inbox_control c"),inboxFields);
  const incidents=row(sql("SELECT json_agg(json_build_object('enabled',enabled,'notifications_enabled',notifications_enabled)) FROM private.incident_control"),['enabled','notifications_enabled']);
  const result={};
  for(const [field,value] of Object.entries(inbox))result[`inbox.${field}`]=value;
  for(const [field,value] of Object.entries(incidents))result[`incidents.${field}`]=value;
  for(const [table,fields] of optionalControls) {
    const installed=sql(`SELECT to_regclass('${table}') IS NOT NULL`);
    if(installed==='f')continue;
    if(installed!=='t')throw Error('Verification draft inventory is unknown.');
    // Only setup_repair_enabled is an optional additive column, never enabled.
    const pairs=fields.map(field=>`'${field}',${field==='setup_repair_enabled'?"COALESCE((to_jsonb(c)->>'setup_repair_enabled')::BOOLEAN,false)":`c.${field}`}`).join(',');
    const values=row(sql(`SELECT json_agg(json_build_object(${pairs})) FROM ${table} c`),fields);
    for(const [field,value] of Object.entries(values))result[`${table}.${field}`]=value;
  }
  return result;
}
