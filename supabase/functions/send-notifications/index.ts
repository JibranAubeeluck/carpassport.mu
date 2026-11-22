// send-notifications — delivers queued rows from public.notifications via Resend.
//
// Triggered by a Database Webhook on INSERT into public.notifications.
// Each run also sweeps any older queued rows and retries failed ones (max 3 attempts),
// so a missed or failed run is picked up by the next notification.
//
// Rows are only ever written by SECURITY DEFINER functions (cp_claim_notify etc.),
// so this function sends nothing that the database did not already queue.
//
// Secrets: RESEND_API_KEY (required). Optional: NOTIFY_FROM, NOTIFY_REPLY_TO.

import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM = Deno.env.get("NOTIFY_FROM") ?? "carpassport.mu Claims <claims@fixit.mu>";
const REPLY_TO = Deno.env.get("NOTIFY_REPLY_TO") ?? "carpassport@fixit.mu";
const MAX_ATTEMPTS = 3;
const BATCH = 25;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async () => {
  if (!RESEND_API_KEY) return json({ error: "RESEND_API_KEY secret is not set" }, 500);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: rows, error } = await db
    .from("notifications")
    .select("id, recipient, subject, body, attempts, status")
    .eq("channel", "email")
    .or(`status.eq.queued,and(status.eq.failed,attempts.lt.${MAX_ATTEMPTS})`)
    .order("id")
    .limit(BATCH);
  if (error) return json({ error: error.message }, 500);

  const results: { id: number; ok: boolean; detail?: string }[] = [];

  for (const n of rows ?? []) {
    // Overlapping runs may pick the same row; the Idempotency-Key below makes
    // Resend deliver it only once.
    const attempts = n.attempts + 1;
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
        // Same key on every retry: Resend will not deliver the same notification twice.
        "Idempotency-Key": `notification-${n.id}`,
      },
      body: JSON.stringify({
        from: FROM,
        to: [n.recipient],
        reply_to: REPLY_TO,
        subject: n.subject,
        text: n.body,
        tags: [{ name: "notification_id", value: String(n.id) }],
      }),
    });
    const out = await res.json().catch(() => ({}));

    if (res.ok) {
      await db
        .from("notifications")
        .update({ status: "sent", attempts, sent_at: new Date().toISOString(), provider_message_id: out.id, error: null })
        .eq("id", n.id);
      results.push({ id: n.id, ok: true });
    } else {
      const detail = `${res.status} ${out.message ?? out.name ?? ""}`.trim().slice(0, 500);
      await db.from("notifications").update({ status: "failed", attempts, error: detail }).eq("id", n.id);
      results.push({ id: n.id, ok: false, detail });
    }

    await sleep(600); // stay under Resend's per-second rate limit
  }

  return json({ processed: results.length, results });
});
