import StaffInbox from "@/components/staff-inbox";
import { StaffInboxRollout } from "@/components/staff-inbox-rollout";
import { loadInboxRollout } from "@/lib/staff-inbox-health";
import { getRenderStaff } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import Link from 'next/link';
import { recoveryUIEnabled } from '@/lib/inbox-recovery';

export const dynamic = "force-dynamic";
export default async function InboxPage() {
  const staff=await getRenderStaff();
  if (!staff) redirect("/login");
  const inboxHealth = staff.role === "super_admin" ? await loadInboxRollout() : undefined;
  return <>
    {inboxHealth !== undefined && <StaffInboxRollout health={inboxHealth} />}
    {recoveryUIEnabled(staff.role)&&<p className="operator-actions"><Link prefetch={false} className="btn-secondary" href="/inbox/operations">Notification operations</Link></p>}
    <StaffInbox governance={process.env.ADMIN_GOVERNANCE_NOTICES_UI==="true"} />
  </>;
}
