# Email setup (Resend)

Set up 22 Nov 2026.

## Auth emails (password reset, sign-up confirmation)
- Supabase → Authentication → SMTP Settings: host `smtp.resend.com`, port `465`, username `resend`.
- Password: Resend key `carpassport-supabase-smtp-v3` (sending-only, fixit.mu).
- Sender: `CarPassport <noreply@fixit.mu>`. Rate limit: 30 emails/hour (Authentication → Rate limits).

## Claim notification emails
1. `cp_report_claim` / `cp_staff_claim_step` call `cp_claim_notify`, which inserts two rows into `public.notifications` (insurer and owner). Status is `queued`, or `no_recipient` if there's no email.
2. Database webhook `send_notifications_on_insert` (INSERT on `public.notifications`, uses pg_net) calls the Edge Function `send-notifications` (`supabase/functions/send-notifications`).
3. The function sends every `queued` row, and retries `failed` rows up to 3 attempts, through the Resend API. It uses `Idempotency-Key: notification-<id>` so no row is delivered twice.
4. On success it sets `status='sent'`, `sent_at` and `provider_message_id` (the Resend message id, kept as the audit trail). On failure it sets `status='failed'` and `error`.

Config:
- Edge Function secret `RESEND_API_KEY`: Resend key `carpassport-claims-notifications` (sending-only, fixit.mu).
- Optional secrets `NOTIFY_FROM` (default `carpassport.mu Claims <claims@fixit.mu>`) and `NOTIFY_REPLY_TO` (default `carpassport@fixit.mu`).
- Migration: `supabase/migrations/20261122_notifications_sender.sql`.

Deploy with the CLI: `supabase functions deploy send-notifications`. It was first deployed from the dashboard editor.

## Domain and DNS
- The Resend domain is `fixit.mu` (verified, region eu-west-1).
- DNS is at StackDNS, edited in the Mauritius.biz control panel. Records: `resend._domainkey` TXT (DKIM), `send` and `rsend` CNAMEs, and `_dmarc` TXT `v=DMARC1; p=none;`.
- The root MX stays on `mx.stackmail.com`, which keeps the human mailboxes working (contact@, carpassport@). Don't add Resend's receiving MX on the root.

## Open items
- None of the 12 `claim_insurers` rows has a `claims_email` yet, so insurer notices are marked `no_recipient` until those are filled in.
- Once carpassport.mu is bought: add the domain in Resend, then update `NOTIFY_FROM` and the Supabase SMTP sender.
