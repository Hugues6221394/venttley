import "server-only";

import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import type { ImpactReport, ImpactReportValue } from "@/lib/impact";

export function reportCsv(report: ImpactReport, values: ImpactReportValue[]): string {
  const metadata = [
    ["report_id", report.report_id], ["title", report.title], ["kind", report.report_kind],
    ["audience", report.audience], ["window_start", report.window_start], ["window_end", report.window_end],
    ["country_source", report.country_source], ["country_filter", report.country_filter ?? ""],
    ["methodology_version", report.methodology_version], ["minimum_cohort", report.minimum_cohort],
    ["generated_at", report.generated_at], ["checksum", report.checksum ?? ""],
  ];
  const headers = ["metric_key","title","pillar","value","previous_value","percent_change","sample_size","suppressed","quality_status","definition","formula","source"];
  return [
    ...metadata.map((row) => row.map(csvCell).join(",")),
    "",
    headers.join(","),
    ...values.map((value) => headers.map((key) => csvCell(String((value as unknown as Record<string, unknown>)[key] ?? ""))).join(",")),
  ].join("\n");
}

export function reportXlsx(report: ImpactReport, values: ImpactReportValue[]): Buffer {
  const rows: (string | number | boolean | null)[][] = [
    ["Venttly Impact & Evidence Report"],
    ["Title", report.title], ["Report id", report.report_id], ["Type", report.report_kind],
    ["Audience", report.audience], ["Window", `${report.window_start} to ${report.window_end}`],
    ["Country source", report.country_source], ["Country filter", report.country_filter],
    ["Methodology", report.methodology_version], ["Minimum cohort", report.minimum_cohort],
    ["Generated", report.generated_at], ["Checksum", report.checksum], [],
    ["Metric key","Title","Pillar","Value","Previous","Change %","Sample","Suppressed","Quality","Definition","Formula","Source"],
    ...values.map((v) => [v.metric_key,v.title,v.pillar,numeric(v.metric_value),numeric(v.previous_value),numeric(v.percent_change),v.sample_size,v.suppressed,v.quality_status,v.definition,v.formula,v.source]),
  ];
  const sheet = worksheetXml(rows, new Set([1, 14]));
  return zipStore([
    ["[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>`],
    ["_rels/.rels", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`],
    ["xl/workbook.xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Impact report" sheetId="1" r:id="rId1"/></sheets></workbook>`],
    ["xl/_rels/workbook.xml.rels", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`],
    ["xl/styles.xml", `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>`],
    ["xl/worksheets/sheet1.xml", sheet],
  ]);
}

export async function reportPdf(report: ImpactReport, values: ImpactReportValue[]): Promise<Uint8Array> {
  const document = await PDFDocument.create();
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const size: [number, number] = [595.28, 841.89];
  const margin = 46;
  let page = document.addPage(size);
  let y = size[1] - margin;
  const draw = (text: string, fontSize = 9, strong = false, color = rgb(0.18,0.12,0.18)) => {
    const lines = wrapPdf(safePdf(text), fontSize, size[0]-2*margin);
    for (const line of lines) {
      if (y < margin + 20) { page = document.addPage(size); y = size[1]-margin; }
      page.drawText(line,{x:margin,y,font:strong?bold:regular,size:fontSize,color});
      y -= fontSize + 4;
    }
  };
  draw("Venttly Impact & Evidence Report",18,true,rgb(0.48,0.15,0.38));
  draw(report.title,14,true); y -= 4;
  draw(`${report.report_kind} | ${report.audience} | ${report.window_start} to ${report.window_end}`);
  draw(`Methodology ${report.methodology_version} | minimum cohort ${report.minimum_cohort}`);
  draw(`Report id ${report.report_id}`); draw(`Checksum ${report.checksum ?? "unavailable"}`); y -= 10;
  draw("Interpretation",11,true);
  draw("Usage and reach are not impact by themselves. Suppressed values are below the privacy threshold. Observational metrics do not prove causality or clinical benefit.",9,false,rgb(0.35,0.32,0.35)); y -= 8;
  for (const value of values) {
    draw(`${value.title}: ${display(value)}`,10,true);
    draw(`${value.definition} Source: ${value.source}. Sample: ${value.sample_size}. Quality: ${value.quality_status}.`,8,false,rgb(0.35,0.32,0.35));
    y -= 6;
  }
  return document.save();
}

function display(value: ImpactReportValue): string {
  if (value.suppressed) return "Suppressed";
  if (value.metric_value === null) return "Unavailable";
  return String(value.metric_value);
}

function numeric(value: string | number | null): string | number | null {
  if (value === null) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : String(value);
}

function csvCell(value: string | number): string {
  let text = String(value);
  if (/^[=+\-@]/.test(text)) text = `'${text}`;
  return /[",\n\r]/.test(text) ? `"${text.replaceAll('"','""')}"` : text;
}

function worksheetXml(rows: (string | number | boolean | null)[][], boldRows: Set<number>): string {
  const body = rows.map((row,rowIndex) => `<row r="${rowIndex+1}">${row.map((value,columnIndex) => {
    const ref = `${columnName(columnIndex+1)}${rowIndex+1}`;
    const style = boldRows.has(rowIndex+1) ? ` s="1"` : "";
    if (typeof value === "number") return `<c r="${ref}"${style}><v>${value}</v></c>`;
    if (typeof value === "boolean") return `<c r="${ref}" t="b"${style}><v>${value?1:0}</v></c>`;
    return `<c r="${ref}" t="inlineStr"${style}><is><t xml:space="preserve">${xml(value == null ? "" : String(value))}</t></is></c>`;
  }).join("")}</row>`).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="3" width="24" customWidth="1"/><col min="4" max="9" width="14" customWidth="1"/><col min="10" max="12" width="46" customWidth="1"/></cols><sheetData>${body}</sheetData></worksheet>`;
}

function columnName(index: number): string {
  let output = "";
  for (let value=index; value>0; value=Math.floor((value-1)/26)) output=String.fromCharCode(65+((value-1)%26))+output;
  return output;
}

function xml(value: string): string { return value.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;").replaceAll("'","&apos;"); }

function zipStore(files: [string,string][]): Buffer {
  const locals: Buffer[]=[]; const centrals: Buffer[]=[]; let offset=0;
  for (const [name,text] of files) {
    const filename=Buffer.from(name,"utf8"); const data=Buffer.from(text,"utf8"); const crc=crc32(data);
    const local=Buffer.alloc(30); local.writeUInt32LE(0x04034b50,0); local.writeUInt16LE(20,4); local.writeUInt32LE(crc,14); local.writeUInt32LE(data.length,18); local.writeUInt32LE(data.length,22); local.writeUInt16LE(filename.length,26);
    locals.push(local,filename,data);
    const central=Buffer.alloc(46); central.writeUInt32LE(0x02014b50,0); central.writeUInt16LE(20,4); central.writeUInt16LE(20,6); central.writeUInt32LE(crc,16); central.writeUInt32LE(data.length,20); central.writeUInt32LE(data.length,24); central.writeUInt16LE(filename.length,28); central.writeUInt32LE(offset,42);
    centrals.push(central,filename); offset+=local.length+filename.length+data.length;
  }
  const centralSize=centrals.reduce((sum,item)=>sum+item.length,0); const end=Buffer.alloc(22); end.writeUInt32LE(0x06054b50,0); end.writeUInt16LE(files.length,8); end.writeUInt16LE(files.length,10); end.writeUInt32LE(centralSize,12); end.writeUInt32LE(offset,16);
  return Buffer.concat([...locals,...centrals,end]);
}

const crcTable = Array.from({length:256},(_,n)=>{ let c=n; for(let k=0;k<8;k++) c=(c&1)?0xedb88320^(c>>>1):c>>>1; return c>>>0; });
function crc32(buffer: Buffer): number { let crc=0xffffffff; for(const byte of buffer) crc=crcTable[(crc^byte)&0xff]^(crc>>>8); return (crc^0xffffffff)>>>0; }

function safePdf(value: string): string { return value.replace(/[\u0000-\u001f\u007f]/g," ").replace(/[^\u0020-\u00ff]/g,"?"); }
function wrapPdf(value: string, fontSize: number, width: number): string[] {
  const max=Math.max(12,Math.floor(width/(fontSize*0.52))); const words=value.split(/\s+/); const lines:string[]=[]; let line="";
  for(const word of words){ const next=line?`${line} ${word}`:word; if(next.length>max&&line){lines.push(line);line=word;}else line=next; } if(line)lines.push(line); return lines.length?lines:[""];
}
