import StaffInbox from "@/components/staff-inbox";
import { getRenderStaff } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import Link from 'next/link';
import { recoveryUIEnabled } from '@/lib/inbox-recovery';

export const dynamic = "force-dynamic";
export default async function InboxPage() {
  const staff=await getRenderStaff();
  if (!staff) redirect("/login");
  return <>{recoveryUIEnabled(staff.role)&&<p className="operator-actions"><Link prefetch={false} className="btn-secondary" href="/inbox/operations">Notification operations</Link></p>}<StaffInbox governance={process.env.ADMIN_GOVERNANCE_NOTICES_UI==="true"} /></>;
}
