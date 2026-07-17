-- =============================================================================
-- GYM MANAGEMENT — COMPLETE SUPABASE SCHEMA
-- =============================================================================
-- Target project : https://ubofngegxapjkkygkcht.supabase.co
--
-- HOW TO RUN
--   1. Open your Supabase project -> SQL Editor -> New query.
--   2. Paste this entire file and press RUN.
--   3. Scroll to section 14 FIRST and change the admin email / password.
--   4. After it succeeds, check Authentication -> Users: the admin account
--      must be listed there and must be able to sign in from the app.
--
-- The script is idempotent: it is safe to run more than once. Every object is
-- created with IF NOT EXISTS / CREATE OR REPLACE, and the seed data is guarded
-- with ON CONFLICT DO NOTHING.
--
-- SECTIONS
--   1. Extensions
--   2. Enums
--   3. Helper functions (auth user creation, permission checks)
--   4. Reference tables (roles, sports, brands, categories)
--   5. Workers, permissions, acomptes, absences, worker payments
--   6. Athletes, subscriptions, seances, free sessions (seance libre)
--   7. Retail (suppliers, clients, products, purchase + sales invoices)
--   8. Money (expenses, cash transactions / caisse)
--   9. Store settings
--  10. Triggers (updated_at, worker payment totals)
--  11. Storage buckets + storage policies
--  12. Row Level Security policies
--  13. Reporting views
--  14. Seed: admin account + default data   <-- EDIT CREDENTIALS HERE
-- =============================================================================


-- =============================================================================
-- 1. EXTENSIONS
-- =============================================================================
create extension if not exists "pgcrypto" with schema extensions;   -- crypt(), gen_salt(), gen_random_uuid()
create extension if not exists "uuid-ossp" with schema extensions;


-- =============================================================================
-- 2. ENUMS
-- =============================================================================
do $$ begin
  create type public.pay_type       as enum ('daily', 'monthly');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.worker_status  as enum ('active', 'inactive');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.cash_direction as enum ('deposit', 'withdraw');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.invoice_status as enum ('paid', 'partial', 'pending', 'debt');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.credit_type    as enum ('deposit', 'used', 'refund');
exception when duplicate_object then null; end $$;


-- =============================================================================
-- 3. HELPER FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- create_auth_user(email, password, full_name)
-- -----------------------------------------------------------------------------
-- Creates a real user in auth.users so the account can sign in with
-- signInWithPassword() from the app. Supabase normally does this through the
-- Admin API; doing it in SQL requires writing both auth.users AND
-- auth.identities, otherwise the email/password provider is not linked and
-- login fails with "Invalid login credentials".
--
-- Returns the new user's id, or the existing user's id if the email is taken.
-- -----------------------------------------------------------------------------
create or replace function public.create_auth_user(
  p_email    text,
  p_password text,
  p_name     text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid;
begin
  -- Reuse the account if this email already exists (keeps the script idempotent).
  select id into v_user_id from auth.users where email = lower(p_email);
  if v_user_id is not null then
    return v_user_id;
  end if;

  v_user_id := extensions.gen_random_uuid();

  insert into auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    invited_at,
    confirmation_token,
    confirmation_sent_at,
    recovery_token,
    recovery_sent_at,
    email_change_token_new,
    email_change,
    email_change_sent_at,
    last_sign_in_at,
    raw_app_meta_data,
    raw_user_meta_data,
    is_super_admin,
    created_at,
    updated_at,
    phone,
    phone_confirmed_at,
    phone_change,
    phone_change_token,
    phone_change_sent_at,
    email_change_token_current,
    email_change_confirm_status,
    banned_until,
    reauthentication_token,
    reauthentication_sent_at,
    is_sso_user,
    deleted_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_user_id,
    'authenticated',
    'authenticated',
    lower(p_email),
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),          -- email pre-confirmed: no verification mail needed
    null,
    '',
    null,
    '',
    null,
    '',
    '',
    null,
    null,
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', coalesce(p_name, '')),
    false,
    now(),
    now(),
    null,
    null,
    '',
    '',
    null,
    '',
    0,
    null,
    '',
    null,
    false,
    null
  );

  -- Without this row the email provider is not linked and login will fail.
  insert into auth.identities (
    id,
    user_id,
    provider_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  ) values (
    extensions.gen_random_uuid(),
    v_user_id,
    v_user_id::text,
    jsonb_build_object(
      'sub',            v_user_id::text,
      'email',          lower(p_email),
      'email_verified', true,
      'phone_verified', false
    ),
    'email',
    now(),
    now(),
    now()
  );

  return v_user_id;
end;
$$;

comment on function public.create_auth_user is
  'Creates a sign-in-capable auth user (users + identities). Used by the seed block and by the admin bootstrap.';


-- NOTE: the permission helpers (is_admin / can_view / can_do) live in section
-- 9.5, after the tables they query. Postgres validates SQL function bodies at
-- creation time, so they cannot be defined up here.

-- Generic updated_at trigger.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;


-- =============================================================================
-- 4. REFERENCE TABLES
-- =============================================================================

create table if not exists public.roles (
  id          uuid primary key default extensions.gen_random_uuid(),
  name        text not null unique,
  -- is_admin roles bypass every permission check (see public.is_admin()).
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.sports (
  id          uuid primary key default extensions.gen_random_uuid(),
  name        text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists public.brands (
  id          uuid primary key default extensions.gen_random_uuid(),
  name        text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists public.categories (
  id          uuid primary key default extensions.gen_random_uuid(),
  name        text not null unique,
  created_at  timestamptz not null default now()
);


-- =============================================================================
-- 5. WORKERS + PERMISSIONS + PAY
-- =============================================================================

create table if not exists public.workers (
  id              uuid primary key default extensions.gen_random_uuid(),

  -- Identity
  first_name      text not null,
  last_name       text not null,
  full_name       text generated always as (first_name || ' ' || last_name) stored,
  birthday        date,
  id_card_number  text,                       -- optional, per spec
  phone           text,
  email           text,
  address         text,
  photo_url       text,                       -- -> storage bucket 'worker-photos'

  role_id         uuid references public.roles(id) on delete set null,

  -- Payment configuration.
  -- pay_enabled=false means this worker is simply not paid through the app.
  pay_enabled     boolean not null default false,
  pay_type        public.pay_type,            -- 'daily' | 'monthly'
  pay_amount      numeric(12,2) not null default 0 check (pay_amount >= 0),

  start_date      date not null default current_date,   -- date started working
  status          public.worker_status not null default 'active',

  -- Login account. NULL user_id = worker exists but cannot sign in.
  user_id         uuid unique references auth.users(id) on delete set null,
  username        text unique,
  account_active  boolean not null default false,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- If a worker is paid, we must know how and how much.
  constraint workers_pay_config_valid check (
    pay_enabled = false or (pay_type is not null and pay_amount > 0)
  )
);

create index if not exists workers_role_id_idx  on public.workers(role_id);
create index if not exists workers_user_id_idx  on public.workers(user_id);
create index if not exists workers_status_idx   on public.workers(status);

-- -----------------------------------------------------------------------------
-- worker_permissions
-- -----------------------------------------------------------------------------
-- One row per GRANTED permission (absence of a row = denied).
--   action_key IS NULL  -> the interface is visible in the sidebar
--   action_key = 'edit' -> that button action is allowed inside the interface
--
-- The catalog of interfaces/actions lives in the app (src/lib/permissions.ts)
-- so it always matches the real routes and buttons.
-- -----------------------------------------------------------------------------
create table if not exists public.worker_permissions (
  id             uuid primary key default extensions.gen_random_uuid(),
  worker_id      uuid not null references public.workers(id) on delete cascade,
  interface_key  text not null,
  action_key     text,
  created_at     timestamptz not null default now()
);

-- A partial unique index per branch: NULL is not comparable with = in a unique
-- constraint, so the interface-level rows need their own index.
create unique index if not exists worker_permissions_iface_uniq
  on public.worker_permissions(worker_id, interface_key)
  where action_key is null;

create unique index if not exists worker_permissions_action_uniq
  on public.worker_permissions(worker_id, interface_key, action_key)
  where action_key is not null;

create index if not exists worker_permissions_worker_idx
  on public.worker_permissions(worker_id);

-- -----------------------------------------------------------------------------
-- worker_payments — a settlement of a period.
-- -----------------------------------------------------------------------------
create table if not exists public.worker_payments (
  id                 uuid primary key default extensions.gen_random_uuid(),
  worker_id          uuid not null references public.workers(id) on delete cascade,

  -- Period being settled (inclusive).
  period_start       date not null,
  period_end         date not null,

  -- Computed breakdown, stored so history stays accurate even if the
  -- worker's pay_amount changes later.
  gross_amount       numeric(12,2) not null default 0,   -- days/months * rate
  acomptes_total     numeric(12,2) not null default 0,   -- advances deducted
  absences_total     numeric(12,2) not null default 0,   -- absence costs deducted
  computed_amount    numeric(12,2) not null default 0,   -- gross - acomptes - absences

  -- What was actually handed over. Defaults to computed_amount but the admin
  -- can override it manually (per spec).
  final_amount       numeric(12,2) not null default 0,
  is_manual_override boolean not null default false,

  payment_date       date not null default current_date, -- editable
  description        text,                               -- optional
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint worker_payments_period_valid check (period_end >= period_start)
);

create index if not exists worker_payments_worker_idx on public.worker_payments(worker_id);
create index if not exists worker_payments_date_idx   on public.worker_payments(payment_date);

-- -----------------------------------------------------------------------------
-- worker_acomptes — salary advances.
-- -----------------------------------------------------------------------------
-- settled_payment_id links the advance to the payment that deducted it.
-- NULL = "not yet decreased from the payment" -> the Payment screen lists it.
-- -----------------------------------------------------------------------------
create table if not exists public.worker_acomptes (
  id                 uuid primary key default extensions.gen_random_uuid(),
  worker_id          uuid not null references public.workers(id) on delete cascade,
  acompte_date       date not null default current_date,
  description        text,
  amount             numeric(12,2) not null check (amount > 0),
  settled_payment_id uuid references public.worker_payments(id) on delete set null,
  created_at         timestamptz not null default now()
);

create index if not exists worker_acomptes_worker_idx on public.worker_acomptes(worker_id);
create index if not exists worker_acomptes_open_idx
  on public.worker_acomptes(worker_id) where settled_payment_id is null;

-- -----------------------------------------------------------------------------
-- worker_absences — absences with a cost deducted from pay.
-- -----------------------------------------------------------------------------
create table if not exists public.worker_absences (
  id                 uuid primary key default extensions.gen_random_uuid(),
  worker_id          uuid not null references public.workers(id) on delete cascade,
  absence_date       date not null default current_date,
  description        text,
  cost               numeric(12,2) not null default 0 check (cost >= 0),
  settled_payment_id uuid references public.worker_payments(id) on delete set null,
  created_at         timestamptz not null default now()
);

create index if not exists worker_absences_worker_idx on public.worker_absences(worker_id);
create index if not exists worker_absences_open_idx
  on public.worker_absences(worker_id) where settled_payment_id is null;


-- =============================================================================
-- 6. ATHLETES
-- =============================================================================

create table if not exists public.athletes (
  id                  uuid primary key default extensions.gen_random_uuid(),
  first_name          text not null,
  last_name           text not null,
  full_name           text generated always as (first_name || ' ' || last_name) stored,
  email               text,
  phone               text,
  date_of_birth       date,
  gender              text,
  address             text,
  sport_id            uuid references public.sports(id) on delete set null,

  subscription_status text default 'inactive',
  subscription_expiry date,
  last_payment        date,
  total_paid          numeric(12,2) not null default 0,
  account_balance     numeric(12,2) not null default 0,

  rfid_uid            text unique,          -- uppercase hex, e.g. 'A3F2C1D4'
  photo_url           text,                 -- -> storage bucket 'athlete-photos'

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists athletes_rfid_idx   on public.athletes(rfid_uid);
create index if not exists athletes_status_idx on public.athletes(subscription_status);
create index if not exists athletes_sport_idx  on public.athletes(sport_id);

create table if not exists public.subscriptions (
  id            uuid primary key default extensions.gen_random_uuid(),
  name          text not null,
  duration      integer not null default 0,   -- days; 0 = open-ended
  sessions      integer,                      -- optional session count
  price         numeric(12,2) not null default 0,
  description   text,
  is_open       boolean not null default false,
  created_at    timestamptz not null default now()
);

create table if not exists public.athlete_subscriptions (
  id               uuid primary key default extensions.gen_random_uuid(),
  athlete_id       uuid not null references public.athletes(id) on delete cascade,
  subscription_id  uuid references public.subscriptions(id) on delete set null,
  name             text not null,
  price            numeric(12,2) not null default 0,
  payment_date     date not null default current_date,
  expiry_date      date,
  amount_paid      numeric(12,2) not null default 0,
  remaining        numeric(12,2) generated always as (price - amount_paid) stored,
  created_at       timestamptz not null default now()
);

create index if not exists athlete_subs_athlete_idx on public.athlete_subscriptions(athlete_id);
create index if not exists athlete_subs_date_idx    on public.athlete_subscriptions(payment_date);
-- Powers the Caisse "sold payments / outstanding" list.
create index if not exists athlete_subs_debt_idx
  on public.athlete_subscriptions(athlete_id) where amount_paid < price;

create table if not exists public.athlete_credits (
  id           uuid primary key default extensions.gen_random_uuid(),
  athlete_id   uuid not null references public.athletes(id) on delete cascade,
  amount       numeric(12,2) not null,
  credit_date  date not null default current_date,
  description  text,
  type         public.credit_type not null,
  created_at   timestamptz not null default now()
);

create index if not exists athlete_credits_athlete_idx on public.athlete_credits(athlete_id);

create table if not exists public.seances_history (
  id                      uuid primary key default extensions.gen_random_uuid(),
  athlete_id              uuid not null references public.athletes(id) on delete cascade,
  athlete_subscription_id uuid references public.athlete_subscriptions(id) on delete cascade,
  seances_used            integer not null default 1,
  seances_remaining       integer not null default 0,
  used_at                 timestamptz not null default now(),
  notes                   text
);

create index if not exists seances_history_athlete_idx on public.seances_history(athlete_id);
create index if not exists seances_history_date_idx    on public.seances_history(used_at);

-- -----------------------------------------------------------------------------
-- free_sessions — "seance libre"
-- -----------------------------------------------------------------------------
-- Either a registered athlete (athlete_id) OR a walk-in (passenger_name).
-- Feeds the Caisse and the Reports screens.
-- -----------------------------------------------------------------------------
create table if not exists public.free_sessions (
  id              uuid primary key default extensions.gen_random_uuid(),
  athlete_id      uuid references public.athletes(id) on delete set null,
  passenger_name  text,                       -- "athlete as passager" (walk-in)
  price           numeric(12,2) not null check (price >= 0),
  session_date    date not null default current_date,
  session_time    time not null default localtime,
  notes           text,
  created_at      timestamptz not null default now(),

  -- Must identify who trained: a member or a named walk-in.
  constraint free_sessions_who check (
    athlete_id is not null or nullif(trim(passenger_name), '') is not null
  )
);

create index if not exists free_sessions_date_idx    on public.free_sessions(session_date desc);
create index if not exists free_sessions_athlete_idx on public.free_sessions(athlete_id);


-- =============================================================================
-- 7. RETAIL
-- =============================================================================

create table if not exists public.suppliers (
  id                  uuid primary key default extensions.gen_random_uuid(),
  name                text not null,
  phone               text,
  address             text,
  total_purchases     numeric(12,2) not null default 0,
  last_purchase_date  date,
  created_at          timestamptz not null default now()
);

create table if not exists public.clients (
  id           uuid primary key default extensions.gen_random_uuid(),
  name         text not null,
  phone        text,
  address      text,
  created_at   timestamptz not null default now()
);

create table if not exists public.products (
  id                uuid primary key default extensions.gen_random_uuid(),
  barcode           text unique,
  name              text not null,
  category_id       uuid references public.categories(id) on delete set null,
  brand_id          uuid references public.brands(id) on delete set null,
  real_price        numeric(12,2) not null default 0,   -- cost
  sell_price        numeric(12,2) not null default 0,
  initial_quantity  integer not null default 0,
  current_stock     integer not null default 0,
  sold              integer not null default 0,
  supplier_id       uuid references public.suppliers(id) on delete set null,
  expiry_date       date,
  description       text,
  min_stock_level   integer not null default 5,
  location          text,
  image_url         text,                              -- -> bucket 'product-images'
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists products_barcode_idx  on public.products(barcode);
create index if not exists products_category_idx on public.products(category_id);

-- Stock status is derived, never stored: it cannot drift out of sync.
create or replace function public.product_status(p_stock integer, p_min integer)
returns text
language sql
immutable
as $$
  select case
    when p_stock <= 0                             then 'out_of_stock'
    when p_stock <= greatest(coalesce(p_min,5),1) then 'critical'
    when p_stock <= greatest(coalesce(p_min,5),1) * 2 then 'low_stock'
    else 'in_stock'
  end;
$$;

create table if not exists public.purchase_invoices (
  id              uuid primary key default extensions.gen_random_uuid(),
  invoice_number  text not null unique,
  supplier_id     uuid references public.suppliers(id) on delete set null,
  total_amount    numeric(12,2) not null default 0,
  amount_paid     numeric(12,2) not null default 0,
  invoice_date    date not null default current_date,
  status          public.invoice_status not null default 'pending',
  notes           text,
  document_url    text,                              -- -> bucket 'documents'
  created_at      timestamptz not null default now()
);

create index if not exists purchase_invoices_date_idx     on public.purchase_invoices(invoice_date);
create index if not exists purchase_invoices_supplier_idx on public.purchase_invoices(supplier_id);

-- Items are a real table (the Dexie version embedded a JSON array, which made
-- per-product reporting impossible).
create table if not exists public.purchase_invoice_items (
  id                  uuid primary key default extensions.gen_random_uuid(),
  purchase_invoice_id uuid not null references public.purchase_invoices(id) on delete cascade,
  product_id          uuid references public.products(id) on delete set null,
  product_name        text not null,
  barcode             text,
  quantity            integer not null default 0,
  purchase_price      numeric(12,2) not null default 0,
  selling_price       numeric(12,2) not null default 0,
  min_stock_level     integer,
  expiry_date         date,
  line_total          numeric(12,2) generated always as (quantity * purchase_price) stored
);

create index if not exists purchase_items_invoice_idx on public.purchase_invoice_items(purchase_invoice_id);

create table if not exists public.sales_invoices (
  id              uuid primary key default extensions.gen_random_uuid(),
  invoice_number  text not null unique,
  client_id       uuid references public.clients(id) on delete set null,
  customer_name   text not null,                     -- or "client de passage"
  customer_email  text,
  client_phone    text,
  creation_date   date not null default current_date,
  due_date        date,
  status          public.invoice_status not null default 'paid',
  subtotal        numeric(12,2) not null default 0,
  discount        numeric(12,2) not null default 0,
  total_amount    numeric(12,2) not null default 0,
  amount_paid     numeric(12,2) not null default 0,
  payment_method  text,
  notes           text,
  created_at      timestamptz not null default now()
);

create index if not exists sales_invoices_date_idx   on public.sales_invoices(creation_date);
create index if not exists sales_invoices_client_idx on public.sales_invoices(client_id);
create index if not exists sales_invoices_status_idx on public.sales_invoices(status);

create table if not exists public.sales_invoice_items (
  id               uuid primary key default extensions.gen_random_uuid(),
  sales_invoice_id uuid not null references public.sales_invoices(id) on delete cascade,
  product_id       uuid references public.products(id) on delete set null,
  name             text not null,
  type             text not null default 'produit',  -- abonnement|produit|service|autre
  quantity         integer not null default 1,
  unit_price       numeric(12,2) not null default 0,
  total            numeric(12,2) generated always as (quantity * unit_price) stored
);

create index if not exists sales_items_invoice_idx on public.sales_invoice_items(sales_invoice_id);


-- =============================================================================
-- 8. MONEY — EXPENSES + CAISSE
-- =============================================================================

create table if not exists public.expenses (
  id            uuid primary key default extensions.gen_random_uuid(),
  name          text not null,
  amount        numeric(12,2) not null check (amount >= 0),
  expense_date  date not null default current_date,
  notes         text,
  receipt_url   text,                            -- -> bucket 'documents'
  created_at    timestamptz not null default now()
);

create index if not exists expenses_date_idx on public.expenses(expense_date);

-- -----------------------------------------------------------------------------
-- cash_transactions — the Caisse ledger (manual deposits / withdrawals).
-- -----------------------------------------------------------------------------
create table if not exists public.cash_transactions (
  id                uuid primary key default extensions.gen_random_uuid(),
  direction         public.cash_direction not null,
  amount            numeric(12,2) not null check (amount > 0),
  transaction_date  date not null default current_date,
  description       text,
  created_by        uuid references public.workers(id) on delete set null,
  created_at        timestamptz not null default now()
);

create index if not exists cash_tx_date_idx      on public.cash_transactions(transaction_date desc);
create index if not exists cash_tx_direction_idx on public.cash_transactions(direction);


-- =============================================================================
-- 9. STORE SETTINGS
-- =============================================================================
-- Single-row table. The CHECK on id enforces "only one row can ever exist".
create table if not exists public.store_settings (
  id            text primary key default 'store' check (id = 'store'),
  name          text default 'GYM',
  description   text,
  email         text,
  phone         text,
  address       text,
  nif           text,
  nis           text,
  article       text,
  rc            text,
  logo_url      text,                            -- -> bucket 'store-logos'
  currency      text not null default 'DZD',
  updated_at    timestamptz not null default now()
);


-- =============================================================================
-- 9.5 PERMISSION HELPERS
-- =============================================================================
-- Defined here (not in section 3) because Postgres validates SQL function
-- bodies at creation time and these query the tables above.
-- STABLE + security definer so Postgres caches them per statement, and so a
-- worker can evaluate their own permissions without needing SELECT rights on
-- the permission tables themselves.

-- Is the current JWT an admin? Admin = worker row whose role is flagged is_admin.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workers w
    join public.roles r on r.id = w.role_id
    where w.user_id = auth.uid()
      and r.is_admin = true
      and w.status = 'active'
  );
$$;

-- Does the current user have this interface visible in the sidebar?
create or replace function public.can_view(p_interface text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1
    from public.worker_permissions wp
    join public.workers w on w.id = wp.worker_id
    where w.user_id = auth.uid()
      and w.status = 'active'
      and wp.interface_key = p_interface
      and wp.action_key is null      -- NULL action = the interface itself
  );
$$;

-- Does the current user have a specific button action on an interface?
-- An action implies nothing about visibility; both are granted explicitly.
create or replace function public.can_do(p_interface text, p_action text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1
    from public.worker_permissions wp
    join public.workers w on w.id = wp.worker_id
    where w.user_id = auth.uid()
      and w.status = 'active'
      and wp.interface_key = p_interface
      and wp.action_key = p_action
  );
$$;

-- The worker row belonging to the caller (used for self-service reads).
create or replace function public.current_worker_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.workers where user_id = auth.uid() limit 1;
$$;


-- =============================================================================
-- 10. TRIGGERS
-- =============================================================================

drop trigger if exists trg_workers_updated       on public.workers;
create trigger trg_workers_updated       before update on public.workers
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_athletes_updated      on public.athletes;
create trigger trg_athletes_updated      before update on public.athletes
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_products_updated      on public.products;
create trigger trg_products_updated      before update on public.products
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_wpayments_updated     on public.worker_payments;
create trigger trg_wpayments_updated     before update on public.worker_payments
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_store_updated         on public.store_settings;
create trigger trg_store_updated         before update on public.store_settings
  for each row execute function public.touch_updated_at();

-- Default final_amount to the computed amount unless the admin overrode it.
create or replace function public.default_final_amount()
returns trigger
language plpgsql
as $$
begin
  if new.is_manual_override = false then
    new.final_amount := new.computed_amount;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_wpayments_final on public.worker_payments;
create trigger trg_wpayments_final before insert or update on public.worker_payments
  for each row execute function public.default_final_amount();


-- =============================================================================
-- 11. STORAGE BUCKETS
-- =============================================================================
-- One bucket per upload surface in the app.
--
--   athlete-photos  (public)  AddAthlete / EditAthlete profile photos
--   worker-photos   (public)  worker profile photos
--   store-logos     (public)  gym logo, printed on invoices + membership cards
--   card-images     (public)  membership card background images (Cards/Scanner)
--   product-images   (public)  product pictures
--   documents       (PRIVATE) scanned ID cards, receipts, invoice scans
--
-- Public buckets are readable by URL, which is what lets <img src> work without
-- a signed request. 'documents' stays private because it holds ID scans —
-- those must be fetched with a short-lived signed URL instead.
--
-- The DB stores only the resulting URL (athletes.photo_url, workers.photo_url,
-- store_settings.logo_url, products.image_url, expenses.receipt_url,
-- purchase_invoices.document_url) — never base64, which is what the old
-- IndexedDB version did.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('athlete-photos', 'athlete-photos', true,  5242880,
     array['image/jpeg','image/png','image/webp','image/gif']),
  ('worker-photos',  'worker-photos',  true,  5242880,
     array['image/jpeg','image/png','image/webp','image/gif']),
  ('store-logos',    'store-logos',    true,  2097152,
     array['image/jpeg','image/png','image/webp','image/svg+xml']),
  ('card-images',    'card-images',    true,  5242880,
     array['image/jpeg','image/png','image/webp']),
  ('product-images', 'product-images', true,  5242880,
     array['image/jpeg','image/png','image/webp']),
  ('documents',      'documents',      false, 10485760,
     array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;


-- ---- Storage policies --------------------------------------------------------
-- Anyone (even signed out) may READ the public buckets so images render.
-- Only signed-in users may write.

drop policy if exists "public buckets are readable"      on storage.objects;
create policy "public buckets are readable"
  on storage.objects for select
  using (bucket_id in ('athlete-photos','worker-photos','store-logos','card-images','product-images'));

drop policy if exists "authenticated can upload images"  on storage.objects;
create policy "authenticated can upload images"
  on storage.objects for insert to authenticated
  with check (bucket_id in ('athlete-photos','worker-photos','store-logos','card-images','product-images'));

drop policy if exists "authenticated can update images"  on storage.objects;
create policy "authenticated can update images"
  on storage.objects for update to authenticated
  using (bucket_id in ('athlete-photos','worker-photos','store-logos','card-images','product-images'));

drop policy if exists "authenticated can delete images"  on storage.objects;
create policy "authenticated can delete images"
  on storage.objects for delete to authenticated
  using (bucket_id in ('athlete-photos','worker-photos','store-logos','card-images','product-images'));

-- 'documents' is private: signed-in users only, for every operation.
drop policy if exists "documents are private"            on storage.objects;
create policy "documents are private"
  on storage.objects for all to authenticated
  using (bucket_id = 'documents')
  with check (bucket_id = 'documents');


-- =============================================================================
-- 12. ROW LEVEL SECURITY
-- =============================================================================
-- Every table is RLS-protected. Without this, the anon key shipped in the app
-- would let anyone read and write the whole database.

alter table public.roles                  enable row level security;
alter table public.sports                 enable row level security;
alter table public.brands                 enable row level security;
alter table public.categories             enable row level security;
alter table public.workers                enable row level security;
alter table public.worker_permissions     enable row level security;
alter table public.worker_payments        enable row level security;
alter table public.worker_acomptes        enable row level security;
alter table public.worker_absences        enable row level security;
alter table public.athletes               enable row level security;
alter table public.subscriptions          enable row level security;
alter table public.athlete_subscriptions  enable row level security;
alter table public.athlete_credits        enable row level security;
alter table public.seances_history        enable row level security;
alter table public.free_sessions          enable row level security;
alter table public.suppliers              enable row level security;
alter table public.clients                enable row level security;
alter table public.products               enable row level security;
alter table public.purchase_invoices      enable row level security;
alter table public.purchase_invoice_items enable row level security;
alter table public.sales_invoices         enable row level security;
alter table public.sales_invoice_items    enable row level security;
alter table public.expenses               enable row level security;
alter table public.cash_transactions      enable row level security;
alter table public.store_settings         enable row level security;

-- -----------------------------------------------------------------------------
-- Helper: apply a standard "interface-gated" policy set to a table.
-- read  -> can_view(interface)
-- write -> can_do(interface, 'create'|'edit'|'delete')
-- -----------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('athletes',               'athletes'),
      ('subscriptions',          'subscriptions'),
      ('athlete_subscriptions',  'athletes'),
      ('athlete_credits',        'athletes'),
      ('seances_history',        'athletes'),
      ('free_sessions',          'athletes'),
      ('suppliers',              'suppliers'),
      ('clients',                'clients'),
      ('products',               'products'),
      ('purchase_invoices',      'purchase_invoices'),
      ('purchase_invoice_items', 'purchase_invoices'),
      ('sales_invoices',         'invoices'),
      ('sales_invoice_items',    'invoices'),
      ('expenses',               'expenses'),
      ('cash_transactions',      'caisse')
    ) as t(tbl, iface)
  loop
    execute format('drop policy if exists %I on public.%I', r.tbl || '_select', r.tbl);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.can_view(%L))',
      r.tbl || '_select', r.tbl, r.iface);

    execute format('drop policy if exists %I on public.%I', r.tbl || '_insert', r.tbl);
    execute format(
      'create policy %I on public.%I for insert to authenticated with check (public.can_do(%L, ''create''))',
      r.tbl || '_insert', r.tbl, r.iface);

    execute format('drop policy if exists %I on public.%I', r.tbl || '_update', r.tbl);
    execute format(
      'create policy %I on public.%I for update to authenticated using (public.can_do(%L, ''edit''))',
      r.tbl || '_update', r.tbl, r.iface);

    execute format('drop policy if exists %I on public.%I', r.tbl || '_delete', r.tbl);
    execute format(
      'create policy %I on public.%I for delete to authenticated using (public.can_do(%L, ''delete''))',
      r.tbl || '_delete', r.tbl, r.iface);
  end loop;
end $$;

-- ---- Reference tables: any signed-in user may read; admin-only writes --------
do $$
declare
  t text;
begin
  foreach t in array array['roles','sports','brands','categories'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_select', t);

    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())',
      t || '_write', t);
  end loop;
end $$;

-- ---- Workers -----------------------------------------------------------------
-- A worker can always read their OWN row (the app needs it at login to resolve
-- role + permissions), plus anyone with the 'workers' interface can read all.
drop policy if exists workers_select on public.workers;
create policy workers_select on public.workers
  for select to authenticated
  using (user_id = auth.uid() or public.can_view('workers'));

drop policy if exists workers_insert on public.workers;
create policy workers_insert on public.workers
  for insert to authenticated with check (public.can_do('workers', 'create'));

drop policy if exists workers_update on public.workers;
create policy workers_update on public.workers
  for update to authenticated using (public.can_do('workers', 'edit'));

drop policy if exists workers_delete on public.workers;
create policy workers_delete on public.workers
  for delete to authenticated using (public.can_do('workers', 'delete'));

-- ---- Worker permissions ------------------------------------------------------
-- Self-read is REQUIRED: the app fetches the signed-in worker's own permissions
-- to build the sidebar. Only the 'permissions' action may change them.
drop policy if exists worker_permissions_select on public.worker_permissions;
create policy worker_permissions_select on public.worker_permissions
  for select to authenticated
  using (worker_id = public.current_worker_id() or public.can_view('workers'));

drop policy if exists worker_permissions_write on public.worker_permissions;
create policy worker_permissions_write on public.worker_permissions
  for all to authenticated
  using (public.can_do('workers', 'permissions'))
  with check (public.can_do('workers', 'permissions'));

-- ---- Worker money tables -----------------------------------------------------
-- A worker may see their own pay history / acomptes / absences.
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('worker_payments', 'payment'),
      ('worker_acomptes', 'acompte'),
      ('worker_absences', 'absence')
    ) as t(tbl, act)
  loop
    execute format('drop policy if exists %I on public.%I', r.tbl || '_select', r.tbl);
    execute format(
      'create policy %I on public.%I for select to authenticated using (worker_id = public.current_worker_id() or public.can_view(''workers''))',
      r.tbl || '_select', r.tbl);

    execute format('drop policy if exists %I on public.%I', r.tbl || '_write', r.tbl);
    execute format(
      'create policy %I on public.%I for all to authenticated using (public.can_do(''workers'', %L)) with check (public.can_do(''workers'', %L))',
      r.tbl || '_write', r.tbl, r.act, r.act);
  end loop;
end $$;

-- ---- Store settings ----------------------------------------------------------
-- Everyone signed in must read it (gym name + logo appear in the sidebar).
drop policy if exists store_settings_select on public.store_settings;
create policy store_settings_select on public.store_settings
  for select to authenticated using (true);

drop policy if exists store_settings_write on public.store_settings;
create policy store_settings_write on public.store_settings
  for all to authenticated
  using (public.can_do('settings', 'edit'))
  with check (public.can_do('settings', 'edit'));


-- =============================================================================
-- 12.5 GRANTS
-- =============================================================================
-- Supabase normally grants these through default privileges on the public
-- schema, but that only fires for tables created after those defaults are set.
-- Granting explicitly makes the script safe on any project state.
--
-- These are table-level grants ONLY: RLS above still decides which ROWS each
-- user can touch. Without the grants the app fails with "permission denied for
-- table X" before RLS is ever consulted.

grant usage on schema public to anon, authenticated, service_role;

grant all on all tables    in schema public to authenticated, service_role;
grant all on all sequences in schema public to authenticated, service_role;
grant all on all functions in schema public to authenticated, service_role;

-- anon is pre-login only. It needs to read store_settings so the login screen
-- can show the gym name/logo, and to call the admin-bootstrap helpers.
grant select on public.store_settings to anon;

alter default privileges in schema public
  grant all on tables    to authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to authenticated, service_role;
alter default privileges in schema public
  grant all on functions to authenticated, service_role;


-- =============================================================================
-- 13. REPORTING VIEWS
-- =============================================================================
-- These power the Reports and Caisse screens. Views run with the privileges of
-- the querying user, so the RLS policies above still apply through them.

-- Every inbound cash movement in one shape, tagged by source interface.
create or replace view public.v_revenue_stream as
  select
    'subscription'::text            as source,
    'athletes'::text                as interface_key,
    s.id                            as ref_id,
    s.payment_date                  as entry_date,
    s.amount_paid                   as amount,
    coalesce(a.full_name, 'N/A')    as label,
    s.name                          as detail
  from public.athlete_subscriptions s
  left join public.athletes a on a.id = s.athlete_id
  where s.amount_paid > 0

  union all
  select
    'free_session',
    'athletes',
    f.id,
    f.session_date,
    f.price,
    coalesce(a.full_name, f.passenger_name, 'Passager'),
    'Seance libre ' || to_char(f.session_time, 'HH24:MI')
  from public.free_sessions f
  left join public.athletes a on a.id = f.athlete_id

  union all
  select
    'sale',
    'invoices',
    i.id,
    i.creation_date,
    i.amount_paid,
    i.customer_name,
    i.invoice_number
  from public.sales_invoices i
  where i.amount_paid > 0

  union all
  select
    'cash_deposit',
    'caisse',
    c.id,
    c.transaction_date,
    c.amount,
    'Depot',
    coalesce(c.description, '')
  from public.cash_transactions c
  where c.direction = 'deposit';

-- Every outbound cash movement.
create or replace view public.v_expense_stream as
  select
    'expense'::text        as source,
    'expenses'::text       as interface_key,
    e.id                   as ref_id,
    e.expense_date         as entry_date,
    e.amount               as amount,
    e.name                 as label,
    coalesce(e.notes, '')  as detail
  from public.expenses e

  union all
  select
    'worker_payment',
    'workers',
    p.id,
    p.payment_date,
    p.final_amount,
    coalesce(w.full_name, 'N/A'),
    coalesce(p.description, 'Salaire')
  from public.worker_payments p
  left join public.workers w on w.id = p.worker_id

  union all
  select
    'worker_acompte',
    'workers',
    ac.id,
    ac.acompte_date,
    ac.amount,
    coalesce(w.full_name, 'N/A'),
    coalesce(ac.description, 'Acompte')
  from public.worker_acomptes ac
  left join public.workers w on w.id = ac.worker_id
  where ac.settled_payment_id is null   -- unsettled advances are real cash out

  union all
  select
    'purchase',
    'purchase_invoices',
    pi.id,
    pi.invoice_date,
    pi.amount_paid,
    coalesce(s.name, 'N/A'),
    pi.invoice_number
  from public.purchase_invoices pi
  left join public.suppliers s on s.id = pi.supplier_id
  where pi.amount_paid > 0

  union all
  select
    'cash_withdraw',
    'caisse',
    c.id,
    c.transaction_date,
    c.amount,
    'Retrait',
    coalesce(c.description, '')
  from public.cash_transactions c
  where c.direction = 'withdraw';

-- Outstanding athlete balances — the Caisse "sold payments" list.
create or replace view public.v_athlete_outstanding as
  select
    a.id                      as athlete_id,
    a.full_name,
    a.phone,
    a.photo_url,
    s.id                      as subscription_id,
    s.name                    as subscription_name,
    s.price,
    s.amount_paid,
    s.remaining,
    s.payment_date,
    s.expiry_date
  from public.athlete_subscriptions s
  join public.athletes a on a.id = s.athlete_id
  where s.amount_paid < s.price;

-- Current caisse balance: everything in minus everything out.
create or replace view public.v_caisse_balance as
  select
    (select coalesce(sum(amount), 0) from public.v_revenue_stream) as total_in,
    (select coalesce(sum(amount), 0) from public.v_expense_stream) as total_out,
    (select coalesce(sum(amount), 0) from public.v_revenue_stream)
      - (select coalesce(sum(amount), 0) from public.v_expense_stream) as balance;


-- =============================================================================
-- 13.5 ADMIN BOOTSTRAP  (powers the "Create admin account" button on Login)
-- =============================================================================
-- These two functions are callable while SIGNED OUT, so they are written to be
-- safe in that state.
--
-- SECURITY MODEL: bootstrap_admin() refuses the moment ANY admin exists. That
-- single rule is what makes the flow safe *and* is what makes the button
-- disappear: the app calls admin_exists() and hides the button once it is true.
-- The check and the insert happen in one statement under a lock, so two people
-- clicking at the same time cannot both create an admin.
-- =============================================================================

-- Does the gym already have an admin? Safe to expose: leaks only a boolean.
create or replace function public.admin_exists()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workers w
    join public.roles r on r.id = w.role_id
    where r.is_admin = true
      and w.user_id is not null
  );
$$;

create or replace function public.bootstrap_admin(
  p_email      text,
  p_password   text,
  p_first_name text default 'Admin',
  p_last_name  text default 'User'
)
returns json
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_role_id uuid;
  v_user_id uuid;
begin
  -- Serialise concurrent bootstrap attempts.
  lock table public.workers in exclusive mode;

  if public.admin_exists() then
    raise exception 'An admin account already exists.'
      using errcode = '42501';
  end if;

  if p_password is null or length(p_password) < 8 then
    raise exception 'Password must be at least 8 characters.'
      using errcode = '22023';
  end if;

  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'A valid email is required.'
      using errcode = '22023';
  end if;

  insert into public.roles (name, is_admin) values ('Admin', true)
    on conflict (name) do update set is_admin = true
    returning id into v_role_id;

  if v_role_id is null then
    select id into v_role_id from public.roles where name = 'Admin';
  end if;

  v_user_id := public.create_auth_user(p_email, p_password,
                                       p_first_name || ' ' || p_last_name);

  insert into public.workers (
    first_name, last_name, email, role_id, user_id,
    account_active, pay_enabled, status, start_date
  ) values (
    p_first_name, p_last_name, lower(p_email), v_role_id, v_user_id,
    true, false, 'active', current_date
  )
  on conflict (user_id) do update
    set role_id = excluded.role_id, account_active = true, status = 'active';

  insert into public.store_settings (id, name) values ('store', 'GYM')
    on conflict (id) do nothing;

  return json_build_object('success', true, 'user_id', v_user_id, 'email', lower(p_email));
end;
$$;

-- Only these two are exposed to signed-out users.
revoke all on function public.bootstrap_admin(text,text,text,text) from public;
revoke all on function public.create_auth_user(text,text,text)     from public, anon, authenticated;
grant execute on function public.admin_exists()                     to anon, authenticated;
grant execute on function public.bootstrap_admin(text,text,text,text) to anon;


-- =============================================================================
-- 14. SEED  —  *** EDIT THE ADMIN CREDENTIALS BELOW BEFORE RUNNING ***
-- =============================================================================
-- NOTE ON THE LOGIN "Create admin account" BUTTON
--   That button only appears while NO admin exists (the app asks admin_exists()).
--   So pick ONE of these:
--     * v_create_admin := true   -> admin is created here; the button never shows.
--     * v_create_admin := false  -> no admin; create it from the login screen,
--                                   and the button disappears once you do.
--   Either way you end up with exactly one admin.
do $$
declare
  -- >>> CHANGE THESE LINES <<<
  v_create_admin   boolean := true;            -- false = create it from the UI instead
  v_admin_email    text := 'admin@gym.com';
  v_admin_password text := 'Admin@2026';
  -- <<< CHANGE THESE LINES >>>

  v_admin_role_id  uuid;
  v_worker_role_id uuid;
  v_trainer_role   uuid;
  v_admin_user_id  uuid;
begin
  -- ---- Roles ----------------------------------------------------------------
  insert into public.roles (name, is_admin) values ('Admin', true)
    on conflict (name) do nothing;
  insert into public.roles (name, is_admin) values ('Worker', false)
    on conflict (name) do nothing;
  insert into public.roles (name, is_admin) values ('Trainer', false)
    on conflict (name) do nothing;

  select id into v_admin_role_id  from public.roles where name = 'Admin';
  select id into v_worker_role_id from public.roles where name = 'Worker';
  select id into v_trainer_role   from public.roles where name = 'Trainer';

  -- ---- Admin auth user + worker row -----------------------------------------
  if v_create_admin then
    v_admin_user_id := public.create_auth_user(v_admin_email, v_admin_password, 'Administrator');

    insert into public.workers (
      first_name, last_name, email, role_id, user_id,
      account_active, pay_enabled, status, start_date
    ) values (
      'Admin', 'User', lower(v_admin_email), v_admin_role_id, v_admin_user_id,
      true, false, 'active', current_date
    )
    on conflict (user_id) do update
      set role_id        = excluded.role_id,
          account_active = true,
          status         = 'active';
  end if;

  -- ---- Store settings row ---------------------------------------------------
  insert into public.store_settings (id, name) values ('store', 'GYM')
    on conflict (id) do nothing;

  -- ---- Default sports -------------------------------------------------------
  insert into public.sports (name) values
    ('Musculation'), ('Fitness'), ('Cardio'), ('CrossFit'), ('Boxe'), ('Yoga')
    on conflict (name) do nothing;

  -- ---- Default product categories -------------------------------------------
  insert into public.categories (name) values
    ('Supplements'), ('Boissons'), ('Accessoires'), ('Vetements'), ('Equipement')
    on conflict (name) do nothing;

  raise notice '=================================================';
  raise notice ' Setup complete.';
  if v_create_admin then
    raise notice ' Admin email    : %', v_admin_email;
    raise notice ' Admin password : %', v_admin_password;
    raise notice ' Auth user id   : %', v_admin_user_id;
    raise notice ' Sign in with these at the app login screen.';
  else
    raise notice ' No admin created — use the "Create admin account"';
    raise notice ' button on the login screen to make the first one.';
  end if;
  raise notice '=================================================';
end $$;


-- =============================================================================
-- 15. CREATING WORKER LOGIN ACCOUNTS
-- =============================================================================
-- The app creates worker logins through the Edge Function in
-- supabase/functions/create-worker-account (it needs the service_role key,
-- which must never ship inside a client-side app).
--
-- To create one by hand instead, run:
--
--   do $$
--   declare v_uid uuid;
--   begin
--     v_uid := public.create_auth_user('worker@gym.com', 'Worker@2026', 'Ahmed B');
--     update public.workers
--        set user_id = v_uid, account_active = true
--      where id = '<the worker uuid>';
--   end $$;
--
-- The worker then signs in with that email/password and sees only the
-- interfaces granted in Workers -> Permissions.
-- =============================================================================
