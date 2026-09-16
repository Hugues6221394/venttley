"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { limitAction } from "@/lib/guard";
import { activeStaffRole } from "@/lib/staff";
import { createSsrClient } from "@/lib/supabase/server";
import { enumOf, optStr, reqStr } from "@/lib/validate";

const DATE = /^\d{4}-\d{2}-\d{2}$/;

export async function generateImpactReport(formData: FormData) {
  await limitAction("bulk");
  const supabase = await createSsrClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user || !(await activeStaffRole(supabase,user.id,["super_admin","admin"]))) throw new Error("Not authorized");

  const kind=enumOf(formData,"report_kind",["monthly_impact","community_health","safety_transparency","country_summary","research_readiness"] as const);
  const audience=enumOf(formData,"audience",["internal","external"] as const);
  const source=enumOf(formData,"country_source",["none","declared_residence","technical_signal"] as const);
  const title=reqStr(formData,"title",160); const notes=optStr(formData,"notes",1000);
  const start=reqStr(formData,"window_start",10); const end=reqStr(formData,"window_end",10);
  if(!DATE.test(start)||!DATE.test(end)) throw new Error("Report dates must use YYYY-MM-DD.");
  const startTime=Date.parse(`${start}T00:00:00Z`); const endTime=Date.parse(`${end}T00:00:00Z`);
  if(!Number.isFinite(startTime)||!Number.isFinite(endTime)||endTime<startTime||endTime-startTime>366*86_400_000) throw new Error("Report window must be valid and no longer than 366 days.");
  const country=optStr(formData,"country_filter",80)?.toUpperCase() ?? null;
  if((source==="none") !== (country===null)) throw new Error("Country filter and country source must be supplied together.");

  const id=await rpc<string>("admin_generate_impact_report",{
    p_report_kind:kind,p_title:title,p_audience:audience,p_window_start:start,p_window_end:end,
    p_country_source:source,p_country_filter:country,p_notes:notes,
  });
  revalidatePath("/impact/reports");
  redirect(`/impact/reports?created=${encodeURIComponent(id)}`);
}
