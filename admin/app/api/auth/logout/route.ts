import { NextResponse, type NextRequest } from "next/server";
import { createSsrClient } from "@/lib/supabase/server";

export async function POST(req: NextRequest) {
  const supabase = await createSsrClient();
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL("/login", req.url), 303);
}
