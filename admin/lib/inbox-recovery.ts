import 'server-only';
import { createSsrClient } from './supabase/server';
import { hasModernShell } from './shell-rollout';
import { parseFailedNotices, parseInboxHealth, parseNotificationHistory, type RecoveryCursor, type RecoverySnapshot } from './inbox-recovery-model';

export function recoveryUIEnabled(role?:string) {
  return role==='super_admin' && process.env.ADMIN_INBOX_RECOVERY_UI==='true' &&
    hasModernShell(role,process.env.ADMIN_SHELL_V2,process.env.ADMIN_SHELL_V2_ROLES);
}
export async function readInboxRecovery(cursor?:RecoveryCursor):Promise<RecoverySnapshot> {
  const db=await createSsrClient();
  // Isolated failures: the authorized queue can remain usable if health fails,
  // but mutation controls require a known, enabled control snapshot.
  const [h,f,o]=await Promise.allSettled([
    db.rpc('admin_staff_inbox_health').abortSignal(AbortSignal.timeout(8_000)),
    db.rpc('admin_staff_inbox_failures',{p_after_time:cursor?.at??null,p_after_id:cursor?.id??null,p_limit:31}).abortSignal(AbortSignal.timeout(8_000)),
    db.rpc('admin_staff_notification_observability').abortSignal(AbortSignal.timeout(8_000)),
  ]);
  const health=h.status==='fulfilled'&&!h.value.error?parseInboxHealth(h.value.data):null;
  const rows=f.status==='fulfilled'&&!f.value.error?parseFailedNotices(f.value.data):null;
  const last=rows?.[29];
  const observability=o.status==='fulfilled'&&!o.value.error?parseNotificationHistory(o.value.data):null;
  return {at:new Date().toISOString(),health,items:rows?.slice(0,30)??null,next:rows&&rows.length>30&&last?{at:last.created_at,id:last.event_id}:null,observability};
}
