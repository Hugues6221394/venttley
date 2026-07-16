import { adminClient } from "../_shared/supabase.ts";
import {
  createModerationHandler,
  type ModerationDataClient,
} from "./handler.ts";

Deno.serve(createModerationHandler({
  getClient: () => adminClient() as unknown as ModerationDataClient,
}));
