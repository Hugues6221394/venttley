import { type EmailOtpType } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { createSsrClient } from "@/lib/supabase/server";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type");
  const destination = new URL("/invite", url.origin);

  if (!tokenHash || type !== "invite") {
    destination.searchParams.set("error", "invalid_link");
    const response = NextResponse.redirect(destination);
    response.headers.set("Cache-Control", "private, no-store");
    return response;
  }

  const supabase = await createSsrClient();
  const { error } = await supabase.auth.verifyOtp({
    type: type as EmailOtpType,
    token_hash: tokenHash,
  });
  if (error) destination.searchParams.set("error", "expired_link");
  const response = NextResponse.redirect(destination);
  response.headers.set("Cache-Control", "private, no-store");
  return response;
}
