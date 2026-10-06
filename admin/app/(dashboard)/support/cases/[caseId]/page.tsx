import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { getRenderStaff } from "@/lib/supabase/server";
import { canAccess } from "@/lib/roles";
import { isUuid } from "@/lib/inbox-model";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { ChevronLeft } from "@/components/ui/icons";
import { SupportReply } from "@/components/support-reply";

export const dynamic = "force-dynamic";

type Message = { id: string; author_kind: "member" | "staff"; author_name: string; body: string; created_at: string };
type Conversation = {
  support_case_id: string; subject: string | null; source_kind: string; category: string; priority: string; status: string;
  member_id: string | null; member_pseudonym: string | null; assignee_id: string | null; assignee_name: string | null;
  sla_due_at: string; created_at: string; updated_at: string; member_read_at: string | null; can_reply: boolean;
  messages: Message[];
};

const words = (value: string) => value.replaceAll("_", " ");
const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : "—");
const STATUS_TONE: Record<string, Tone> = { open: "warn", assigned: "warn", waiting_member: "neutral", waiting_internal: "warn", resolved: "ok", closed: "ok" };
const SOURCE: Record<string, string> = {
  member: "Started by the member in the app", staff_message: "Member replied to a staff message",
};

export default async function SupportConversationPage({ params }: { params: Promise<{ caseId: string }> }) {
  const staff = await getRenderStaff();
  if (!staff) redirect("/login");
  const { caseId } = await params;
  if (!isUuid(caseId)) notFound();
  const conversation = await rpc<Conversation>("admin_support_conversation", { p_case: caseId }).catch((error: Error) => {
    if (error.message.includes("not_found")) notFound();
    throw error;
  });

  const handle = conversation.member_pseudonym ? `@${conversation.member_pseudonym}` : "the member";
  const lastStaff = [...conversation.messages].reverse().find(m => m.author_kind === "staff");
  const seen = lastStaff && conversation.member_read_at && conversation.member_read_at >= lastStaff.created_at;
  const waitingOnStaff = conversation.messages.at(-1)?.author_kind === "member" && !["resolved", "closed"].includes(conversation.status);

  return (
    <div className="member-profile">
      <Link href="/support/cases" className="member-back"><ChevronLeft size={14} /> Support cases</Link>

      <header className="member-header">
        <div className="member-identity">
          <div>
            <h1>{conversation.subject || `${words(conversation.category)} case`}</h1>
            <div className="member-meta">
              <Badge tone={STATUS_TONE[conversation.status] ?? "neutral"}>{words(conversation.status)}</Badge>
              <Badge tone={conversation.priority === "critical" ? "danger" : conversation.priority === "high" ? "warn" : "neutral"}>{conversation.priority}</Badge>
              {waitingOnStaff && <span className="text-danger font-semibold">Member is waiting for a reply</span>}
              <span>{conversation.member_id ? handle : "No member on this case"}</span>
              <span className="member-id">{conversation.support_case_id.slice(0, 8)}</span>
            </div>
          </div>
        </div>
        <div className="member-actions">
          {conversation.member_id && canAccess(staff.role, "/users") && (
            <Link href={`/users/${conversation.member_id}?tab=communications`} className="btn-secondary">Member profile</Link>
          )}
          <Link href={`/support/cases?source=${conversation.support_case_id}`} className="btn-ghost">Status &amp; owner</Link>
        </div>
      </header>

      <div className="member-grid">
        <div className="member-side">
          <Card title="Conversation" hint={`${conversation.messages.length} ${conversation.messages.length === 1 ? "message" : "messages"}`} padded={false}>
            {conversation.messages.length === 0 ? (
              <p className="member-empty">No messages yet. A reply below starts the conversation in the member&apos;s app.</p>
            ) : (
              <ol className="support-thread">
                {conversation.messages.map(m => (
                  <li key={m.id} className={`support-message is-${m.author_kind}`}>
                    <div className="support-message-head">
                      <strong>{m.author_kind === "staff" ? `${m.author_name} · Venttly team` : `@${m.author_name}`}</strong>
                      <time dateTime={m.created_at}>{when(m.created_at)}</time>
                    </div>
                    <p className="support-message-body">{m.body}</p>
                  </li>
                ))}
              </ol>
            )}
            {lastStaff && (
              <p className="support-seen">{seen ? `Seen by ${handle} ${when(conversation.member_read_at)}` : `Not opened by ${handle} yet`}</p>
            )}
          </Card>

          <Card title="Reply" padded>
            {conversation.can_reply ? (
              <SupportReply caseId={conversation.support_case_id} handle={handle} />
            ) : (
              <p className="operator-note">
                {conversation.member_id ? "This case is closed. Reopen it from the support queue to reply." : "This case has no member attached, so there is no one to reply to."}
              </p>
            )}
          </Card>
        </div>

        <div className="member-side">
          <Card title="Case" padded>
            <KV label="Origin" value={SOURCE[conversation.source_kind] ?? words(conversation.source_kind)} />
            <KV label="Category" value={words(conversation.category)} />
            <KV label="Owner" value={conversation.assignee_name ?? "Unassigned"} />
            <KV label="Response due" value={when(conversation.sla_due_at)} />
            <KV label="Opened" value={when(conversation.created_at)} />
            <KV label="Last change" value={when(conversation.updated_at)} />
          </Card>
          <p className="member-list-foot">
            Members see every reply as coming from the Venttly team. Replying makes you the owner if the case has none, and the case then waits on the member. Their answer brings it back to the owner with an inbox alert.
          </p>
        </div>
      </div>
    </div>
  );
}
