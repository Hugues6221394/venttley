import { NextResponse, type NextRequest } from "next/server";
import { createRateLimiter, ipFrom } from "@/lib/redis";
import { createSsrClient } from "@/lib/supabase/server";
import { activeStaffRole } from "@/lib/staff";
import { getImpactReport, getImpactReportValues } from "@/lib/impact";
import { reportCsv, reportPdf, reportXlsx } from "@/lib/report-export";

export const dynamic = "force-dynamic";
const limiter=createRateLimiter("impact_report_export",10,300,"deny");
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(req:NextRequest,context:{params:Promise<{reportId:string}>}){
  const {reportId}=await context.params; const format=req.nextUrl.searchParams.get("format")??"csv";
  if(!UUID.test(reportId)||!["csv","xlsx","pdf","json"].includes(format)) return new NextResponse("Invalid export request",{status:400});
  const ssr=await createSsrClient(); const {data:{user}}=await ssr.auth.getUser();
  if(!user) return new NextResponse("Unauthorized",{status:401});
  if(!(await activeStaffRole(ssr,user.id,["super_admin","admin","analyst","read_only_auditor"]))) return new NextResponse("Forbidden",{status:403});
  const gate=await limiter.limit(user.id||ipFrom(req));
  if(!gate.success) return new NextResponse(gate.unavailable?"Export rate limiting is unavailable":"Too many exports",{status:gate.unavailable?503:429});
  const [reportResult,values]=await Promise.all([getImpactReport(reportId),getImpactReportValues(reportId)]);
  const report=reportResult.data;
  if(reportResult.error) return new NextResponse(reportResult.error,{status:503});
  if(!report) return new NextResponse("Report not found",{status:404});
  if(values.error) return new NextResponse(values.error,{status:503});
  const {error:auditError}=await ssr.rpc("admin_log_impact_report_export",{p_report:reportId,p_format:format});
  if(auditError) return new NextResponse(`Export refused: ${auditError.message}`,{status:403});
  const base=`venttly-${report.report_kind}-${report.window_end}`.replace(/[^a-z0-9._-]/gi,"-");
  if(format==="json") return new NextResponse(JSON.stringify({report,metrics:values.data},null,2),{headers:headers("application/json; charset=utf-8",`${base}.json`)});
  if(format==="xlsx") return new NextResponse(new Uint8Array(reportXlsx(report,values.data)),{headers:headers("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",`${base}.xlsx`)});
  if(format==="pdf") {
    const bytes=await reportPdf(report,values.data); const body=new ArrayBuffer(bytes.byteLength); new Uint8Array(body).set(bytes);
    return new NextResponse(body,{headers:headers("application/pdf",`${base}.pdf`)});
  }
  return new NextResponse(reportCsv(report,values.data),{headers:headers("text/csv; charset=utf-8",`${base}.csv`)});
}

function headers(contentType:string,filename:string){return {"Content-Type":contentType,"Content-Disposition":`attachment; filename="${filename}"`,"Cache-Control":"private, no-store, max-age=0","X-Content-Type-Options":"nosniff"};}
