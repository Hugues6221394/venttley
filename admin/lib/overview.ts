import 'server-only';
import { cache } from 'react';
import { createSsrClient, getRenderStaff } from '@/lib/supabase/server';
import { parseSnapshot, type OverviewPanel, type PanelData, type Snapshot } from './overview-model';

// Render-pass cache only; never a permission or response cache across users.
export const readOverviewPanel = cache(async <K extends OverviewPanel>(panel: K): Promise<Snapshot<PanelData[K]>> => {
  const unavailable: Snapshot<PanelData[K]> = { state:'unavailable', measured_at:null, data:null };
  try {
    if (!(await getRenderStaff())) return unavailable;
    const db = await createSsrClient();
    const { data, error } = await db.rpc('admin_overview_panel', { p_panel: panel }).abortSignal(AbortSignal.timeout(8_000));
    return error ? unavailable : parseSnapshot(panel,data) ?? unavailable;
  } catch { return unavailable; }
});
