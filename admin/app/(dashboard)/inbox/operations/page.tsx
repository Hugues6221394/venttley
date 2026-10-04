import { redirect } from 'next/navigation';
import Link from 'next/link';
import { getRenderStaff } from '@/lib/supabase/server';
import { recoveryUIEnabled } from '@/lib/inbox-recovery';
import InboxRecovery from '@/components/inbox-recovery';
import { OperatorPage } from '@/components/ui/operator-workspace';
export const dynamic='force-dynamic';
export default async function NotificationOperationsPage() {
  const staff=await getRenderStaff();
  if(!staff)redirect('/login');
  if(staff.role!=='super_admin')redirect('/overview');
  if(!recoveryUIEnabled(staff.role))return <OperatorPage title="Notification operations" subtitle="The recovery interface is disabled."><p>No processing or delivery settings have changed.</p><Link href="/inbox" className="btn-secondary">Staff inbox</Link></OperatorPage>;
  return <InboxRecovery/>;
}
