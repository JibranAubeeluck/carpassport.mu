-- Surveyor role, surveyor panel, staff management, survey reports on the car profile, contact form.
-- Additive: no existing column, row or behaviour is removed.
-- NOTE: run part 1 on its own first (new enum values must be committed before use).

-- ============ PART 1 (run alone) ============
alter type public.user_role add value if not exists 'surveyor';

-- ============ PART 2 ============
-- Survey outputs live on the inspection itself.
alter table public.inspections add column if not exists score numeric(5,1);
alter table public.inspections add column if not exists certificate_credential text;
alter table public.inspections add column if not exists report_path text;

-- Contact form messages (written only by the contact-message Edge Function, service role).
create table if not exists public.contact_messages (
  id bigint generated always as identity primary key,
  name text not null,
  email text not null,
  phone text,
  reason text,
  vehicle text,
  message text not null,
  ip text,
  status text not null default 'received',
  error text,
  created_at timestamptz not null default now()
);
alter table public.contact_messages enable row level security;

-- ---------- roles ----------
create or replace function public.cp_is_surveyor() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from profiles where id = auth.uid() and role::text in ('surveyor','admin'));
$$;

create or replace function public.cp_require_surveyor() returns uuid
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not cp_is_surveyor() then raise exception 'Surveyor access only.' using errcode = '42501'; end if;
  return auth.uid();
end $$;

create or replace function public.cp_require_admin() returns uuid
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not is_admin() then raise exception 'Admin access only.' using errcode = '42501'; end if;
  return auth.uid();
end $$;

-- Random code from an unambiguous alphabet, grouped in fours: XXXX-XXXX-XXXX
create or replace function public.cp_rand_code(p_len int) returns text
language plpgsql volatile set search_path to 'public' as $$
declare alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; b bytea; r text := '';
begin
  b := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  for i in 0..p_len-1 loop
    r := r || substr(alpha, (get_byte(b, i) % 31) + 1, 1);
    if i % 4 = 3 and i < p_len-1 then r := r || '-'; end if;
  end loop;
  return r;
end $$;

-- ---------- surveyor: vehicles ----------
create or replace function public.cp_surv_find(p_q text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); v_vin text := cp_vin_of(p_q);
begin
  if v_vin is null then return null; end if;
  return cp_vehicle_json(v_vin, 'owner') || jsonb_build_object(
    'has_owner', (select owner_id is not null from vehicles where vin = v_vin),
    'claim_codes', coalesce((select jsonb_agg(jsonb_build_object(
        'code', c.code, 'bound_email', c.bound_email, 'bound_phone', c.bound_phone,
        'expires_at', c.expires_at, 'redeemed_at', c.redeemed_at, 'created_at', c.created_at,
        'issued_by', (select full_name from profiles where id = c.created_by)) order by c.created_at desc)
      from vehicle_claims c where c.vin = v_vin), '[]'::jsonb));
end $$;

create or replace function public.cp_surv_save_vehicle(p jsonb) returns text
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); v_vin text := cp_norm(p->>'vin'); existing text;
begin
  if length(v_vin) not between 8 and 17 then raise exception 'The chassis / VIN must be 8 to 17 letters and digits.'; end if;
  if coalesce(trim(p->>'plate'), '') = '' then raise exception 'Enter the registration number.'; end if;
  if coalesce(trim(p->>'make'), '') = '' or coalesce(trim(p->>'model'), '') = '' then raise exception 'Enter the make and model.'; end if;
  select vin into existing from vehicles where cp_norm(vin) = v_vin;
  if existing is null then
    insert into vehicles (vin, registration_number, make, model, model_year, fuel_type, colour, transmission,
                          engine_number, engine_capacity_cc, body_type, record_status, record_source, verified_at, verified_by)
    values (v_vin, upper(trim(p->>'plate')), trim(p->>'make'), trim(p->>'model'), nullif(p->>'year','')::smallint,
            nullif(p->>'fuel',''), nullif(p->>'colour',''), nullif(p->>'transmission',''),
            nullif(upper(trim(p->>'engine_no')),''), nullif(p->>'engine_cc','')::integer, nullif(p->>'body',''),
            'verified', 'surveyor', now(), uid);
    perform cp_event(v_vin, 'registered_on_carpassport', current_date, jsonb_build_object(
      'title', 'Added to carpassport', 'detail', 'Created by an accredited surveyor after physical inspection',
      'source', 'surveyor', 'verified', true));
    return v_vin;
  end if;
  update vehicles set
    registration_number = upper(trim(p->>'plate')), make = trim(p->>'make'), model = trim(p->>'model'),
    model_year = coalesce(nullif(p->>'year','')::smallint, model_year),
    fuel_type = coalesce(nullif(p->>'fuel',''), fuel_type), colour = coalesce(nullif(p->>'colour',''), colour),
    transmission = coalesce(nullif(p->>'transmission',''), transmission),
    engine_number = coalesce(nullif(upper(trim(p->>'engine_no')),''), engine_number),
    engine_capacity_cc = coalesce(nullif(p->>'engine_cc','')::integer, engine_capacity_cc),
    body_type = coalesce(nullif(p->>'body',''), body_type),
    record_status = 'verified', verified_at = coalesce(verified_at, now()), verified_by = coalesce(verified_by, uid),
    updated_at = now()
  where vin = existing;
  return existing;
end $$;

-- ---------- surveyor: CPSS survey ----------
create or replace function public.cp_surv_save_inspection(p_vin text, p_date date, p_odometer integer,
  p_results jsonb, p_score numeric, p_grade text, p_notes text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); r uuid;
begin
  if not exists (select 1 from vehicles where vin = p_vin) then raise exception 'Vehicle not found.'; end if;
  if p_grade !~ '^[A-F]$' then raise exception 'Invalid grade.'; end if;
  if p_odometer is null or p_odometer < 0 then raise exception 'Enter the odometer reading at inspection.'; end if;
  insert into inspections (vin, inspection_date, inspector_id, cpss_version, cpss_results, overall_grade, score, odometer_km, notes)
  values (p_vin, coalesce(p_date, current_date), uid, '1.0', p_results, p_grade, p_score, p_odometer, nullif(trim(p_notes),''))
  returning id into r;
  insert into odometer_readings (vin, reading_km, reading_date, source, recorded_by)
  values (p_vin, p_odometer, coalesce(p_date, current_date), 'inspection', uid);
  perform cp_event(p_vin, 'survey', coalesce(p_date, current_date), jsonb_build_object(
    'title', 'CPSS survey — grade ' || p_grade, 'detail', 'Physical inspection by an accredited surveyor',
    'odometer', p_odometer, 'source', 'surveyor', 'verified', true));
  return r;
end $$;

create or replace function public.cp_surv_issue_certificate(p_inspection uuid) returns text
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); i inspections; cred text;
begin
  select * into i from inspections where id = p_inspection;
  if not found then raise exception 'Survey not found.'; end if;
  if i.certificate_credential is not null then return i.certificate_credential; end if;
  loop
    cred := 'CP-' || cp_rand_code(8) || '-' || to_char(now(), 'YYYY');
    exit when not exists (select 1 from reports where credential = cred);
  end loop;
  insert into reports (credential, vin, report_type, pages, generated_by)
  values (cred, i.vin, 'CPSS certificate — grade ' || i.overall_grade, 1, uid);
  update inspections set certificate_credential = cred where id = p_inspection;
  return cred;
end $$;

create or replace function public.cp_surv_attach_report(p_inspection uuid, p_path text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); v text;
begin
  select vin into v from inspections where id = p_inspection;
  if v is null then raise exception 'Survey not found.'; end if;
  if p_path is null or p_path not like 'surveys/' || v || '/%' then raise exception 'Upload the report to this vehicle''s survey folder.'; end if;
  update inspections set report_path = p_path where id = p_inspection;
end $$;

-- ---------- surveyor: claim codes ----------
create or replace function public.cp_surv_new_claim_code(p_vin text, p_email text, p_phone text, p_note text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_surveyor(); c text;
begin
  if not exists (select 1 from vehicles where vin = p_vin) then raise exception 'Vehicle not found.'; end if;
  if nullif(trim(p_email),'') is not null and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address isn''t valid.'; end if;
  loop
    c := cp_rand_code(12);
    exit when not exists (select 1 from vehicle_claims where code_key = cp_norm(c));
  end loop;
  insert into vehicle_claims (code, code_key, vin, bound_email, bound_phone, note, expires_at, created_by)
  values (c, cp_norm(c), p_vin, nullif(lower(trim(p_email)),''), nullif(trim(p_phone),''), nullif(trim(p_note),''),
          now() + interval '90 days', uid);
  return c;
end $$;

create or replace function public.cp_surv_my_codes() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when not cp_is_surveyor() then null else coalesce(jsonb_agg(jsonb_build_object(
    'code', c.code, 'vin', c.vin, 'plate', v.registration_number, 'vehicle', concat_ws(' ', v.make, v.model, v.model_year),
    'bound_email', c.bound_email, 'bound_phone', c.bound_phone, 'expires_at', c.expires_at,
    'redeemed_at', c.redeemed_at, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb) end
  from vehicle_claims c join vehicles v on v.vin = c.vin where c.created_by = auth.uid();
$$;

create or replace function public.cp_surv_my_surveys() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when not cp_is_surveyor() then null else coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id, 'vin', i.vin, 'plate', v.registration_number, 'vehicle', concat_ws(' ', v.make, v.model, v.model_year),
    'date', i.inspection_date, 'grade', i.overall_grade, 'score', i.score,
    'certificate', i.certificate_credential, 'report_path', i.report_path) order by i.inspection_date desc, i.created_at desc), '[]'::jsonb) end
  from (select * from inspections where inspector_id = auth.uid() order by inspection_date desc, created_at desc limit 50) i
  join vehicles v on v.vin = i.vin;
$$;

-- ---------- admin: staff ----------
create or replace function public.cp_admin_staff() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.full_name, 'email', coalesce(p.email, u.email), 'role', p.role::text,
      'codes_issued', (select count(*) from vehicle_claims c where c.created_by = p.id),
      'codes_redeemed', (select count(*) from vehicle_claims c where c.created_by = p.id and c.redeemed_at is not null),
      'surveys', (select count(*) from inspections i where i.inspector_id = p.id)) order by p.role::text, p.full_name)
    from profiles p join auth.users u on u.id = p.id where p.role::text in ('admin','surveyor')), '[]'::jsonb);
end $$;

create or replace function public.cp_admin_set_role(p_email text, p_role text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin(); target uuid;
begin
  if p_role not in ('surveyor','user') then raise exception 'Role must be surveyor or user.'; end if;
  select u.id into target from auth.users u where lower(u.email) = lower(trim(p_email));
  if target is null then raise exception 'No account with that email. Ask them to sign up first.'; end if;
  if target = uid then raise exception 'You can''t change your own role.'; end if;
  if exists (select 1 from profiles where id = target and role = 'admin') then raise exception 'That account is an admin.'; end if;
  if not exists (select 1 from profiles where id = target) then
    insert into profiles (id, email, role) values (target, lower(trim(p_email)), p_role::user_role);
  else
    update profiles set role = p_role::user_role where id = target;
  end if;
end $$;

create or replace function public.cp_admin_codes() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'code', c.code, 'plate', v.registration_number, 'vehicle', concat_ws(' ', v.make, v.model),
      'issued_by', coalesce(p.full_name, p.email, 'Unknown'), 'bound_email', c.bound_email,
      'expires_at', c.expires_at, 'redeemed_at', c.redeemed_at, 'created_at', c.created_at) order by c.created_at desc)
    from vehicle_claims c join vehicles v on v.vin = c.vin left join profiles p on p.id = c.created_by), '[]'::jsonb);
end $$;

-- ---------- storage: survey report PDFs in owner-uploads/surveys/<VIN>/ ----------
drop policy if exists "cp surveys: surveyor upload" on storage.objects;
create policy "cp surveys: surveyor upload" on storage.objects for insert
  with check (bucket_id = 'owner-uploads' and (storage.foldername(name))[1] = 'surveys' and public.cp_is_surveyor());
drop policy if exists "cp surveys: owner read" on storage.objects;
create policy "cp surveys: owner read" on storage.objects for select
  using (bucket_id = 'owner-uploads' and (storage.foldername(name))[1] = 'surveys' and public.owns_vehicle((storage.foldername(name))[2]));

-- ---------- grants ----------
revoke all on function public.cp_rand_code(int) from public, anon;
grant execute on function public.cp_is_surveyor(), public.cp_surv_find(text), public.cp_surv_save_vehicle(jsonb),
  public.cp_surv_save_inspection(text, date, integer, jsonb, numeric, text, text), public.cp_surv_issue_certificate(uuid),
  public.cp_surv_attach_report(uuid, text), public.cp_surv_new_claim_code(text, text, text, text), public.cp_surv_my_codes(),
  public.cp_surv_my_surveys(), public.cp_admin_staff(), public.cp_admin_set_role(text, text), public.cp_admin_codes()
  to authenticated;

-- ---------- car profile: list of surveys (owner & staff views) ----------
-- Identical to the previous cp_vehicle_json, plus the 'surveys' key.
CREATE OR REPLACE FUNCTION public.cp_vehicle_json(p_vin text, p_mode text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ declare v vehicles; r jsonb; begin select * into v from vehicles where vin = p_vin; if not found then return null; end if; r := to_jsonb(v) - 'owner_id' - 'verified_by'; r := r || jsonb_build_object( 'odometer', (select max(reading_km) from odometer_readings where vin = p_vin), 'odometer_readings', coalesce((select jsonb_agg(jsonb_build_object('km', reading_km, 'date', reading_date, 'source', source::text, 'rollback', is_rollback) order by reading_date, created_at) from odometer_readings where vin = p_vin), '[]'::jsonb), 'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'type', event_type, 'date', event_date, 'details', coalesce(details, '{}'::jsonb), 'created_at', created_at) order by event_date desc, created_at desc) from ownership_events where vin = p_vin and (p_mode = 'owner' or event_type not in ('claim_reported','claim_settled'))), '[]'::jsonb), 'insurance', (select to_jsonb(i) - 'document_path' from insurance_records i where vin = p_vin order by coalesce(end_date, start_date) desc nulls last, created_at desc limit 1), 'inspection', (select jsonb_build_object('date', inspection_date, 'grade', overall_grade, 'odometer', odometer_km, 'cpss_version', cpss_version) from inspections where vin = p_vin order by inspection_date desc, created_at desc limit 1), 'valuation', (select jsonb_build_object('date', valuation_date, 'value', assessed_value_mur, 'purpose', purpose, 'basis', basis, 'surveyor', surveyor_name) from valuations where vin = p_vin order by valuation_date desc, created_at desc limit 1)); if p_mode = 'owner' then r := r || jsonb_build_object( 'documents', coalesce((select jsonb_agg(jsonb_build_object('kind', coalesce(replace(m.kind, 'doc:', ''), d.doc_type::text), 'path', d.storage_path, 'at', d.created_at) order by d.created_at desc) from vehicle_documents d left join cp_enum_map m on m.kind like 'doc:%' and m.label = d.doc_type::text where d.vin = p_vin), '[]'::jsonb), 'open_transfer', (select to_jsonb(t) - 'seller_id' - 'buyer_id' from vehicle_transfers t where t.vin = p_vin and t.status in ('initiated','accepted') and not (t.status = 'initiated' and t.expires_at < now()) limit 1), 'surveys', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'date', i.inspection_date, 'grade', i.overall_grade, 'score', i.score, 'odometer', i.odometer_km, 'cpss_version', i.cpss_version, 'notes', i.notes, 'certificate', i.certificate_credential, 'report_path', i.report_path, 'surveyor', coalesce((select full_name from profiles where id = i.inspector_id), 'carpassport surveyor')) order by i.inspection_date desc, i.created_at desc) from inspections i where i.vin = p_vin), '[]'::jsonb)); end if; return r; end $function$;
