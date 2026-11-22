// contact-message — public "Contact us" form handler.
//
// 1. Validates the message (and a hidden honeypot field that only bots fill in).
// 2. Rate-limits: max 3 messages per email and 10 per IP address per hour.
// 3. Stores it in public.contact_messages.
// 4. Emails it to the carpassport inbox (Reply-To = the sender) and sends the sender an acknowledgement.
//
// Deployed with JWT verification OFF (the public site calls it with the publishable key).
// Secrets: RESEND_API_KEY (required). Optional: CONTACT_TO, CONTACT_FROM.

import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const TO = Deno.env.get("CONTACT_TO") ?? "carpassport@fixit.mu";
const FROM = Deno.env.get("CONTACT_FROM") ?? "carpassport.mu <noreply@fixit.mu>";
const ALLOWED_ORIGINS = ["https://www.fixit.mu", "https://fixit.mu", "https://carpassport.mu", "https://www.carpassport.mu"];
const REASONS = ["General enquiry", "Request a survey", "Dealership partnership", "Institution (insurer / bank) access", "Owner support"];

const cors = (origin: string | null) => ({
  "Access-Control-Allow-Origin": origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});

const clean = (v: unknown, max: number) => String(v ?? "").replace(/\r/g, "").trim().slice(0, max);
const validEmail = (e: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e);

async function send(payload: Record<string, unknown>, idem: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json", "Idempotency-Key": idem },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const out = await res.json().catch(() => ({}));
    throw new Error(`${res.status} ${out.message ?? out.name ?? ""}`.trim());
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const headers = { ...cors(origin), "Content-Type": "application/json" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(origin) });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  if (!RESEND_API_KEY) return reply({ error: "Email is not configured yet." }, 500);

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return reply({ error: "Invalid request." }, 400); }

  // Honeypot: real visitors never see this field. Pretend success so bots learn nothing.
  if (clean(b.website, 200)) return reply({ ok: true });

  const name = clean(b.name, 120), email = clean(b.email, 200).toLowerCase(), phone = clean(b.phone, 40);
  const reason = REASONS.includes(clean(b.reason, 80)) ? clean(b.reason, 80) : "General enquiry";
  const vehicle = clean(b.vehicle, 200), message = clean(b.message, 5000);
  if (!name || !email || !message) return reply({ error: "Please add your name, email and a message." }, 400);
  if (!validEmail(email)) return reply({ error: "Please enter a valid email address." }, 400);
  if (message.length < 5) return reply({ error: "Please write a little more in your message." }, 400);

  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const hourAgo = new Date(Date.now() - 3600_000).toISOString();

  const { count: byEmail } = await db.from("contact_messages").select("id", { count: "exact", head: true })
    .eq("email", email).gte("created_at", hourAgo);
  const { count: byIp } = ip
    ? await db.from("contact_messages").select("id", { count: "exact", head: true }).eq("ip", ip).gte("created_at", hourAgo)
    : { count: 0 };
  if ((byEmail ?? 0) >= 3 || (byIp ?? 0) >= 10) {
    return reply({ error: "You've sent several messages already — please wait an hour, or email carpassport@fixit.mu directly." }, 429);
  }

  const { data: row, error } = await db.from("contact_messages")
    .insert({ name, email, phone: phone || null, reason, vehicle: vehicle || null, message, ip })
    .select("id").single();
  if (error) return reply({ error: "Couldn't save your message — please try again." }, 500);

  const ref = `CM-${String(row.id).padStart(5, "0")}`;
  const lines = [
    `New message from the carpassport.mu contact form (${ref}).`, "",
    `Name: ${name}`, `Email: ${email}`, phone ? `Phone: ${phone}` : "", `Reason: ${reason}`,
    vehicle ? `Vehicle: ${vehicle}` : "", "", message, "",
    "Reply to this email to answer the sender directly.",
  ].filter((l, i, a) => l !== "" || a[i - 1] !== "");

  try {
    await send({
      from: FROM, to: [TO], reply_to: email,
      subject: `[carpassport.mu] ${reason} — ${name} (${ref})`,
      text: lines.join("\n"),
    }, `contact-${row.id}-inbox`);
    await send({
      from: FROM, to: [email], reply_to: TO,
      subject: `We received your message (${ref})`,
      text: [
        `Dear ${name.split(/\s+/)[0]},`, "",
        "Thank you for contacting carpassport.mu. We've received your message and will reply within one working day (Mon–Fri, 9:00–17:00).", "",
        `Reference: ${ref}`, `Reason: ${reason}`, "", "Your message:", message, "",
        "carpassport.mu — the independent vehicle record for Mauritius",
      ].join("\n"),
    }, `contact-${row.id}-ack`);
    await db.from("contact_messages").update({ status: "sent" }).eq("id", row.id);
  } catch (e) {
    await db.from("contact_messages").update({ status: "failed", error: String(e).slice(0, 500) }).eq("id", row.id);
    return reply({ error: "Your message was saved but the email didn't go out — please also email carpassport@fixit.mu.", ref }, 502);
  }

  return reply({ ok: true, ref });
});
