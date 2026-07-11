import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { audit } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Trash2, Power, ShieldAlert } from "lucide-react";

export const dynamic = "force-dynamic";

type Rule = {
  rule_id: string;
  pattern: string;
  match_type: "contains" | "word" | "regex";
  category: string;
  action: "flag" | "block" | "crisis";
  is_active: boolean;
  note: string | null;
  created_at: string;
};

const ACTION_TONE: Record<Rule["action"], "danger" | "warn" | "crisis"> = {
  block: "danger",
  flag: "warn",
  crisis: "crisis",
};

async function createRuleAction(formData: FormData) {
  "use server";
  const pattern = String(formData.get("pattern") ?? "").trim();
  const match_type = String(formData.get("match_type") ?? "contains");
  const category = String(formData.get("category") ?? "other");
  const action = String(formData.get("action") ?? "block");
  const note = String(formData.get("note") ?? "").trim() || null;
  if (!pattern) return;

  const db = await createAdminClient();
  const { data } = await db
    .from("automod_rules")
    .insert({ pattern, match_type, category, action, note })
    .select("rule_id")
    .maybeSingle();
  await audit("automod.create", {
    targetType: "automod_rule",
    targetId: data?.rule_id,
    after: { pattern, match_type, category, action },
    reason: note ?? undefined,
  });
  revalidatePath("/automod");
}

async function toggleRuleAction(formData: FormData) {
  "use server";
  const id = String(formData.get("rule_id") ?? "");
  const next = String(formData.get("next") ?? "") === "true";
  if (!id) return;
  const db = await createAdminClient();
  await db.from("automod_rules").update({ is_active: next }).eq("rule_id", id);
  await audit("automod.toggle", {
    targetType: "automod_rule",
    targetId: id,
    after: { is_active: next },
  });
  revalidatePath("/automod");
}

async function deleteRuleAction(formData: FormData) {
  "use server";
  const id = String(formData.get("rule_id") ?? "");
  if (!id) return;
  const db = await createAdminClient();
  await db.from("automod_rules").delete().eq("rule_id", id);
  await audit("automod.delete", { targetType: "automod_rule", targetId: id });
  revalidatePath("/automod");
}

export default async function AutomodPage() {
  const db = await createAdminClient();
  const { data } = await db
    .from("automod_rules")
    .select("*")
    .order("created_at", { ascending: false });
  const rules = (data ?? []) as Rule[];
  const active = rules.filter((r) => r.is_active).length;

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Operate"
        title="Automod rules"
        subtitle="Keyword rules the on-device safety classifier loads to extend its built-in lists — no app release needed. Active rules apply to new posts, whispers and chat."
      />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <Card title="Add a rule" hint="Applies within minutes of saving">
          <form action={createRuleAction} className="flex flex-col gap-3">
            <input
              name="pattern"
              required
              placeholder="Word or phrase to match"
              className="w-full rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm focus:border-berry"
            />
            <div className="grid grid-cols-2 gap-2">
              <Select name="match_type" label="Match" options={["contains", "word", "regex"]} />
              <Select
                name="action"
                label="Action"
                options={["block", "flag", "crisis"]}
              />
            </div>
            <Select
              name="category"
              label="Category"
              options={[
                "harassment",
                "hate",
                "sexual_content",
                "violence",
                "privacy",
                "self_harm",
                "other",
              ]}
            />
            <input
              name="note"
              placeholder="Note (optional)"
              className="w-full rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm focus:border-berry"
            />
            <button className="btn-primary" type="submit">
              Add rule
            </button>
            <p className="text-[11px] text-ink-muted">
              &ldquo;crisis&rdquo; never blocks — it surfaces help + flags for the
              Safety queue. &ldquo;block&rdquo; stops the message; &ldquo;flag&rdquo;
              lets it through but records it.
            </p>
          </form>
        </Card>

        <Card
          className="lg:col-span-2"
          title="Rules"
          hint={`${active} active · ${rules.length} total`}
          padded={false}
        >
          {rules.length === 0 ? (
            <div className="p-8">
              <EmptyState
                title="No automod rules yet"
                hint="Add keywords the AI classifier should always catch."
                icon={<ShieldAlert size={26} className="text-berry" />}
              />
            </div>
          ) : (
            <ul className="divide-y divide-line">
              {rules.map((r) => (
                <li key={r.rule_id} className="px-5 py-3 flex items-center gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <code className="font-mono text-sm font-bold text-burgundy break-all">
                        {r.pattern}
                      </code>
                      <Badge tone={ACTION_TONE[r.action]}>{r.action}</Badge>
                      <Badge tone="neutral">{r.match_type}</Badge>
                      <Badge tone="neutral">{r.category}</Badge>
                      {!r.is_active && <Badge tone="neutral">off</Badge>}
                    </div>
                    {r.note && (
                      <p className="text-xs text-ink-muted mt-0.5">{r.note}</p>
                    )}
                  </div>
                  <form action={toggleRuleAction}>
                    <input type="hidden" name="rule_id" value={r.rule_id} />
                    <input type="hidden" name="next" value={(!r.is_active).toString()} />
                    <button
                      className="p-2 rounded-lg hover:bg-canvas text-ink-muted"
                      title={r.is_active ? "Disable" : "Enable"}
                      type="submit"
                    >
                      <Power size={15} className={r.is_active ? "text-ok" : ""} />
                    </button>
                  </form>
                  <form action={deleteRuleAction}>
                    <input type="hidden" name="rule_id" value={r.rule_id} />
                    <button
                      className="p-2 rounded-lg hover:bg-danger/10 text-danger"
                      title="Delete"
                      type="submit"
                    >
                      <Trash2 size={15} />
                    </button>
                  </form>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </div>
  );
}

function Select({
  name,
  label,
  options,
}: {
  name: string;
  label: string;
  options: string[];
}) {
  return (
    <label className="text-[11px] font-semibold text-burgundy/80">
      {label}
      <select
        name={name}
        className="mt-1 w-full rounded-xl border border-mauve/50 bg-white px-2 py-2 text-sm focus:border-berry"
      >
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    </label>
  );
}
