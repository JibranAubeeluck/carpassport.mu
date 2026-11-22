-- Surveyors are trusted Partners, not staff.
-- A surveyor is an approved partner (providers row) offering the 'surveyor' service that an admin has marked trusted.
-- Onboarding: plate + chassis + client mobile + survey (valuation, CPSS grades, notes) → verified profile,
-- certificate, a claim link bound to the client's mobile, and a queue for carpassport to WhatsApp the client.

-- 1. Surveyors no longer count as staff (review queues, claims steps, etc. are admin/staff only).
create or replace function public.cp_is_staff() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from profiles where id = auth.uid() and role::text in ('admin','staff'));
$$;

-- 2. Trusted-surveyor flag on partners.
alter table public.providers add column if not exists surveyor_trusted boolean not null default false;
alter table public.providers add column if not exists surveyor_trusted_at timestamptz;

create or replace function public.cp_my_surveyor() returns public.providers
language sql stable security definer set search_path to 'public' as $$
  select pr.* from profiles p join providers pr on pr.id = p.provider_id
  where p.id = auth.uid() and pr.status = 'approved' and 'surveyor' = any(pr.services) and pr.surveyor_trusted;
$$;

-- Who may onboard: a trusted surveyor partner, or a carpassport admin.
create or replace function public.cp_is_surveyor() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select is_admin() or (cp_my_surveyor()).id is not null;
$$;

-- 3. Onboardings (one per survey-led onboarding).
create table if not exists public.vehicle_onboardings (
  id uuid primary key default gen_random_uuid(),
  vin text not null references public.vehicles(vin),
  provider_id uuid references public.providers(id),
  surveyor_id uuid not null,
  inspection_id uuid references public.inspections(id),
  valuation_id uuid,
  client_phone text not null,
  claim_code text,
  notify_status text not null default 'pending' check (notify_status in ('pending','sent')),
  notified_at timestamptz,
  notified_by uuid,
  created_at timestamptz not null default now()
);
alter table public.vehicle_onboardings enable row level security;

-- 4. Onboard in one call.
create or replace function public.cp_surv_onboard(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); pr providers := cp_my_surveyor(); me profiles;
  v_vin text; v_phone text := regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g');
  v_odo integer := nullif(regexp_replace(coalesce(p->>'odometer',''), '\D', '', 'g'), '')::integer;
  v_value numeric := nullif(regexp_replace(coalesce(p->>'value',''), '[^0-9.]', '', 'g'), '')::numeric;
  insp uuid; val uuid; cert text; code text; has_owner boolean; ob uuid; who text;
begin
  select * into me from profiles where id = uid;
  if length(v_phone) < 7 then raise exception 'Enter the client''s mobile number.'; end if;
  if v_odo is null then raise exception 'Enter the odometer reading.'; end if;
  if v_value is null or v_value <= 0 then raise exception 'Enter the assessed value in MUR.'; end if;
  who := concat_ws(' — ', nullif(me.full_name, ''), coalesce(pr.name, 'carpassport'));

  v_vin := cp_surv_save_vehicle(jsonb_build_object('plate', p->>'plate', 'vin', p->>'vin', 'make', p->>'make',
    'model', p->>'model', 'year', p->>'year', 'colour', p->>'colour', 'fuel', p->>'fuel', 'transmission', p->>'transmission'));
  insp := cp_surv_save_inspection(v_vin, current_date, v_odo, p->'results', nullif(p->>'score','')::numeric,
    p->>'grade', p->>'notes');
  insert into valuations (vin, valuation_date, assessed_value_mur, purpose, basis, surveyor_id, surveyor_name)
  values (v_vin, current_date, v_value, coalesce(nullif(p->>'purpose',''), 'Market value'), nullif(p->>'basis',''), uid, who)
  returning id into val;
  perform cp_event(v_vin, 'valuation', current_date, jsonb_build_object('title', 'Independent valuation',
    'detail', 'Assessed by ' || who, 'source', 'surveyor', 'verified', true));
  cert := cp_surv_issue_certificate(insp);

  select owner_id is not null into has_owner from vehicles where vin = v_vin;
  if not has_owner then
    code := cp_surv_new_claim_code(v_vin, null, v_phone, 'Onboarding by ' || who);
  end if;
  insert into vehicle_onboardings (vin, provider_id, surveyor_id, inspection_id, valuation_id, client_phone, claim_code)
  values (v_vin, pr.id, uid, insp, val, v_phone, code) returning id into ob;
  return jsonb_build_object('id', ob, 'vin', v_vin, 'inspection_id', insp, 'certificate', cert, 'claim_code', code, 'already_linked', has_owner);
end $$;

-- 5. Surveyor's own onboardings.
create or replace function public.cp_surv_my_onboardings() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when not cp_is_surveyor() then null else coalesce(jsonb_agg(jsonb_build_object(
    'id', o.id, 'vin', o.vin, 'plate', v.registration_number, 'vehicle', concat_ws(' ', v.make, v.model, v.model_year),
    'grade', i.overall_grade, 'certificate', i.certificate_credential, 'report_path', i.report_path, 'inspection_id', i.id,
    'value', va.assessed_value_mur, 'notify_status', o.notify_status, 'created_at', o.created_at,
    'linked', (select redeemed_at is not null from vehicle_claims c where c.code = o.claim_code)) order by o.created_at desc), '[]'::jsonb) end
  from (select * from vehicle_onboardings where surveyor_id = auth.uid() order by created_at desc limit 100) o
  join vehicles v on v.vin = o.vin left join inspections i on i.id = o.inspection_id left join valuations va on va.id = o.valuation_id;
$$;

-- 6. Admin: WhatsApp queue, trusted surveyors.
create or replace function public.cp_admin_onboardings() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'vin', o.vin, 'plate', v.registration_number, 'make', v.make, 'model', v.model, 'year', v.model_year,
      'client_phone', o.client_phone, 'claim_code', o.claim_code, 'grade', i.overall_grade, 'certificate', i.certificate_credential,
      'value', va.assessed_value_mur, 'surveyor', va.surveyor_name, 'notify_status', o.notify_status,
      'notified_at', o.notified_at, 'created_at', o.created_at,
      'linked', (select redeemed_at is not null from vehicle_claims c where c.code = o.claim_code))
      order by (o.notify_status = 'pending') desc, o.created_at desc)
    from (select * from vehicle_onboardings where notify_status = 'pending' or created_at > now() - interval '30 days') o
    join vehicles v on v.vin = o.vin left join inspections i on i.id = o.inspection_id left join valuations va on va.id = o.valuation_id), '[]'::jsonb);
end $$;

create or replace function public.cp_admin_mark_onboarding(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  if p_status not in ('pending','sent') then raise exception 'Unknown status.'; end if;
  update vehicle_onboardings set notify_status = p_status,
    notified_at = case when p_status = 'sent' then now() end, notified_by = case when p_status = 'sent' then uid end
  where id = p_id;
end $$;

create or replace function public.cp_admin_surveyor_partners() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', pr.id, 'name', pr.name, 'brn', pr.brn, 'contact_name', pr.contact_name, 'email', pr.email, 'phone', pr.phone,
      'status', pr.status, 'trusted', pr.surveyor_trusted, 'trusted_at', pr.surveyor_trusted_at,
      'onboardings', (select count(*) from vehicle_onboardings o where o.provider_id = pr.id)) order by pr.surveyor_trusted desc, pr.name)
    from providers pr where 'surveyor' = any(pr.services)), '[]'::jsonb);
end $$;

create or replace function public.cp_admin_trust_surveyor(p_provider uuid, p_trusted boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  update providers set surveyor_trusted = p_trusted, surveyor_trusted_at = case when p_trusted then now() end
  where id = p_provider and 'surveyor' = any(services);
  if not found then raise exception 'Partner not found or not a surveyor.'; end if;
end $$;

grant execute on function public.cp_surv_onboard(jsonb), public.cp_surv_my_onboardings(), public.cp_admin_onboardings(),
  public.cp_admin_mark_onboarding(uuid, text), public.cp_admin_surveyor_partners(), public.cp_admin_trust_surveyor(uuid, boolean)
  to authenticated;

-- 7. Allow 'surveyor' as a partner service (constraint + registration). cp_register_provider is unchanged apart from the list.
alter table public.providers drop constraint if exists providers_services_check;
alter table public.providers add constraint providers_services_check
  check (cardinality(services) > 0 and services <@ array['insurer','bank','garage','dealer','surveyor']);

CREATE OR REPLACE FUNCTION public.cp_register_provider(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$ declare uid uuid := cp_require_user(); pid uuid; svc text[]; begin if exists (select 1 from profiles where id = uid and (onboarded_at is not null or provider_id is not null)) then raise exception 'This account already has a profile. Register your organisation with a separate work email.'; end if; select array_agg(x) into svc from jsonb_array_elements_text(p->'services') x; if svc is null or not svc <@ array['insurer','bank','garage','dealer','surveyor'] then raise exception 'Choose at least one valid service.'; end if; if length(trim(coalesce(p->>'name', ''))) < 2 or length(trim(coalesce(p->>'brn', ''))) < 5 or length(trim(coalesce(p->>'contact_name', ''))) < 3 then raise exception 'Organisation name, BRN and account holder are required.'; end if; insert into providers (name, brn, address, services, contact_name, contact_role, email, phone, created_by) values (trim(p->>'name'), upper(trim(p->>'brn')), p->>'address', svc, trim(p->>'contact_name'), p->>'contact_role', (select email from auth.users where id = uid), p->>'phone', null) returning id into pid; insert into profiles (id, email, full_name, phone, role, tier, provider_id, consents, onboarded_at) values (uid, (select email from auth.users where id = uid), trim(p->>'contact_name'), p->>'phone', 'provider', 3, pid, p->'consents', now()) on conflict (id) do update set full_name = excluded.full_name, phone = excluded.phone, role = 'provider', tier = 3, provider_id = pid, consents = excluded.consents, onboarded_at = now(); update providers set created_by = uid where id = pid; return pid; end $function$;
