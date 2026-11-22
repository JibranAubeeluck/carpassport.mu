-- Garage limit (Personal = 5 vehicles), Business licences, and single-choice partner types incl. mechanic / repairer / other.

-- ---------- 1. Plans ----------
alter table public.profiles add column if not exists plan text not null default 'personal';
alter table public.profiles add column if not exists vehicle_limit integer not null default 5;
alter table public.profiles add column if not exists plan_since timestamptz;

-- NULL = no limit. Approved partner accounts (e.g. dealer stock) are not personal garages.
create or replace function public.cp_vehicle_limit(p_uid uuid) returns integer
language sql stable security definer set search_path to 'public' as $$
  select case
    when exists (select 1 from profiles p join providers pr on pr.id = p.provider_id where p.id = p_uid and pr.status = 'approved') then null
    else coalesce((select vehicle_limit from profiles where id = p_uid), 5) end;
$$;

-- One guard for every way a vehicle gets an owner: registration, claim code, transfer, onboarding.
create or replace function public.cp_check_garage_limit() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare lim integer;
begin
  if new.owner_id is null then return new; end if;
  if tg_op = 'UPDATE' and old.owner_id is not distinct from new.owner_id then return new; end if;
  lim := cp_vehicle_limit(new.owner_id);
  if lim is not null and (select count(*) from vehicles where owner_id = new.owner_id and vin <> new.vin) >= lim then
    raise exception 'This garage is limited to % vehicles. Upgrade to a carpassport Business licence to add more.', lim;
  end if;
  return new;
end $$;
drop trigger if exists trg_garage_limit on public.vehicles;
create trigger trg_garage_limit before insert or update of owner_id on public.vehicles
  for each row execute function public.cp_check_garage_limit();

-- ---------- 2. Business licence requests ----------
create table if not exists public.business_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  tier text not null,
  company text not null,
  brn text,
  fleet_size integer,
  phone text,
  message text,
  status text not null default 'pending' check (status in ('pending','active','declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);
alter table public.business_requests enable row level security;

create or replace function public.cp_request_business(p jsonb) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_user(); r uuid;
begin
  if length(trim(coalesce(p->>'tier',''))) < 2 then raise exception 'Choose a licence.'; end if;
  if length(trim(coalesce(p->>'company',''))) < 2 then raise exception 'Enter your company or trading name.'; end if;
  if length(regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g')) < 7 then raise exception 'Enter a contact number.'; end if;
  if exists (select 1 from business_requests where user_id = uid and status = 'pending') then
    raise exception 'You already have a request under review — carpassport will contact you shortly.'; end if;
  insert into business_requests (user_id, tier, company, brn, fleet_size, phone, message)
  values (uid, trim(p->>'tier'), trim(p->>'company'), nullif(upper(trim(p->>'brn')),''),
          nullif(regexp_replace(coalesce(p->>'fleet_size',''), '\D', '', 'g'), '')::integer, trim(p->>'phone'), nullif(trim(p->>'message'),''))
  returning id into r;
  return r;
end $$;

create or replace function public.cp_my_plan() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'plan', p.plan, 'limit', cp_vehicle_limit(p.id),
    'vehicles', (select count(*) from vehicles where owner_id = p.id),
    'request', (select jsonb_build_object('tier', b.tier, 'status', b.status, 'created_at', b.created_at)
                from business_requests b where b.user_id = p.id order by b.created_at desc limit 1)) end
  from profiles p where p.id = auth.uid();
$$;

create or replace function public.cp_admin_business_requests() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'user_id', b.user_id, 'name', p.full_name, 'email', u.email, 'tier', b.tier, 'company', b.company,
      'brn', b.brn, 'fleet_size', b.fleet_size, 'phone', b.phone, 'message', b.message, 'status', b.status,
      'created_at', b.created_at, 'plan', p.plan, 'vehicle_limit', p.vehicle_limit,
      'vehicles', (select count(*) from vehicles v where v.owner_id = b.user_id))
      order by (b.status = 'pending') desc, b.created_at desc)
    from business_requests b join auth.users u on u.id = b.user_id left join profiles p on p.id = b.user_id
    where b.status = 'pending' or b.created_at > now() - interval '90 days'), '[]'::jsonb);
end $$;

-- Activate / change / end a licence. p_plan 'personal' resets the limit to 5.
create or replace function public.cp_admin_set_plan(p_user uuid, p_plan text, p_limit integer, p_request uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := cp_require_admin();
begin
  if coalesce(trim(p_plan),'') = '' then raise exception 'Choose a plan.'; end if;
  if p_plan <> 'personal' and (p_limit is null or p_limit < 6) then raise exception 'A Business licence must allow more than 5 vehicles.'; end if;
  update profiles set plan = p_plan, vehicle_limit = case when p_plan = 'personal' then 5 else p_limit end,
    plan_since = case when p_plan = 'personal' then null else now() end
  where id = p_user;
  if not found then raise exception 'Account not found.'; end if;
  if p_request is not null then
    update business_requests set status = case when p_plan = 'personal' then 'declined' else 'active' end,
      decided_at = now(), decided_by = uid where id = p_request;
  end if;
end $$;

grant execute on function public.cp_request_business(jsonb), public.cp_my_plan(), public.cp_admin_business_requests(),
  public.cp_admin_set_plan(uuid, text, integer, uuid) to authenticated;

-- ---------- 3. Partner types: one per registration; add mechanic, repairer, other ----------
alter table public.providers drop constraint if exists providers_services_check;
alter table public.providers add constraint providers_services_check
  check (cardinality(services) > 0 and services <@ array['insurer','bank','garage','dealer','surveyor','mechanic','repairer','other']);

CREATE OR REPLACE FUNCTION public.cp_register_provider(p jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$ declare uid uuid := cp_require_user(); pid uuid; svc text[]; begin if exists (select 1 from profiles where id = uid and (onboarded_at is not null or provider_id is not null)) then raise exception 'This account already has a profile. Register your organisation with a separate work email.'; end if; select array_agg(x) into svc from jsonb_array_elements_text(p->'services') x; if svc is null or cardinality(svc) <> 1 or not svc <@ array['insurer','bank','garage','dealer','surveyor','mechanic','repairer','other'] then raise exception 'Choose one type of partner.'; end if; if length(trim(coalesce(p->>'name', ''))) < 2 or length(trim(coalesce(p->>'brn', ''))) < 5 or length(trim(coalesce(p->>'contact_name', ''))) < 3 then raise exception 'Organisation name, BRN and account holder are required.'; end if; insert into providers (name, brn, address, services, contact_name, contact_role, email, phone, created_by) values (trim(p->>'name'), upper(trim(p->>'brn')), p->>'address', svc, trim(p->>'contact_name'), p->>'contact_role', (select email from auth.users where id = uid), p->>'phone', null) returning id into pid; insert into profiles (id, email, full_name, phone, role, tier, provider_id, consents, onboarded_at) values (uid, (select email from auth.users where id = uid), trim(p->>'contact_name'), p->>'phone', 'provider', 3, pid, p->'consents', now()) on conflict (id) do update set full_name = excluded.full_name, phone = excluded.phone, role = 'provider', tier = 3, provider_id = pid, consents = excluded.consents, onboarded_at = now(); update providers set created_by = uid where id = pid; return pid; end $function$;
