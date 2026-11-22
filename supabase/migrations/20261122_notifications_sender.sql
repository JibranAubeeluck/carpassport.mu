-- Audit trail for outbound email: Resend's message id for every sent notification.
alter table public.notifications add column if not exists provider_message_id text;

-- The sender only ever scans queued / failed rows.
create index if not exists notifications_outbox_idx
  on public.notifications (id)
  where status in ('queued', 'failed');
