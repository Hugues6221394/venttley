"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { operationalResult, requireOperationalActor } from "@/lib/operational-actions";
import { intInRange, reqStr, uuid } from "@/lib/validate";

function finish(result: string): never {
  revalidatePath("/crisis/playbooks");
  redirect(`/crisis/playbooks?result=${encodeURIComponent(result)}`);
}

export async function createPlaybook(formData: FormData) {
  let result = "draft_created";
  try {
    await requireOperationalActor(["super_admin", "admin"]);
    await rpc("admin_create_crisis_playbook", {
      p_operation: uuid(formData, "operation_id"),
      p_region_code: reqStr(formData, "region_code", 20).toUpperCase(),
      p_version: intInRange(formData, "version", 1, 100000),
      p_title: reqStr(formData, "title", 160),
      p_body_markdown: reqStr(formData, "body_markdown", 12000),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function publishPlaybook(formData: FormData) {
  let result = "playbook_published";
  try {
    await requireOperationalActor(["super_admin"]);
    await rpc("admin_publish_crisis_playbook", {
      p_operation: uuid(formData, "operation_id"),
      p_playbook: uuid(formData, "playbook_id"),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function acknowledgePlaybook(formData: FormData) {
  let result = "playbook_acknowledged";
  try {
    await requireOperationalActor(["super_admin", "admin", "moderator", "support"]);
    await rpc("admin_ack_crisis_playbook", {
      p_operation: uuid(formData, "operation_id"),
      p_playbook: uuid(formData, "playbook_id"),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}
