import { NextResponse, type NextRequest } from "next/server";
import { createSsrClient } from "@/lib/supabase/server";
import { originRejection, sameOrigin } from "@/lib/guard";

export async function POST(req: NextRequest) {
  // Cookie-authenticated and state-changing, so without this any page on the
  // internet could sign an operator out with a plain <form method="post">.
  // Low severity on its own; it is the same missing check that matters on
  // /api/admin/event, and there is no reason to leave one of them open.
  if (!sameOrigin(req)) return originRejection();

  const supabase = await createSsrClient();
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL("/login", req.url), 303);
}
