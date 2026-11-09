-- 09-tagihan.sql — TAGIHAN MEJA (bill): gabung meja, pembayaran campuran, pajak/service/diskon, "minta bill".
-- Jalankan SETELAH 01…06 dan 08. Aman diulang (idempotent). Data pesanan lama dipindahkan ke tagihan otomatis (bagian 4).
--
-- Konsep
--   • Satu TAGIHAN (bills) = satu sesi di satu atau beberapa meja. Pesanan pertama di meja kosong membuka tagihan;
--     pesanan susulan dari meja itu (siapa pun) otomatis masuk tagihan yang sama. Pesanan tetap terpisah per pelanggan.
--   • Kasir menggabungkan 2+ meja (merge_tables), memisahkan pesanan (split_orders), memberi diskon, lalu membayar SEKALI
--     (pay_bill) dengan satu atau beberapa metode. Jumlah pembayaran harus sama dengan total (tidak dicicil).
--   • Pajak & biaya layanan (persen) diatur Owner (set_tenant_billing); nilainya disalin ke tagihan saat lunas.
--   • Pelanggan: maks 15 pelanggan (perangkat) per meja per tagihan; 1 pesanan / 10 detik per perangkat; tombol "Minta bill".

-- =====================================================================
-- 1. PENGATURAN & TABEL
-- =====================================================================
alter table public.tenants
  add column if not exists tax_pct numeric(5,2) not null default 0 check (tax_pct between 0 and 100),
  add column if not exists service_pct numeric(5,2) not null default 0 check (service_pct between 0 and 100);
alter table public.order_counters add column if not exists last_bill_no int4 not null default 0;

create table if not exists public.bills (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  bill_no int4 not null,
  status text not null default 'open' check (status in ('open', 'paid', 'void', 'merged')),
  label text,                                   -- nama bebas untuk tagihan tanpa meja (hasil pemisahan)
  opened_at timestamptz not null default now(),
  bill_requested_at timestamptz,                -- pelanggan menekan "Minta bill"
  bill_requested_label text,                    -- meja yang meminta
  discount_idr int4 not null default 0 check (discount_idr >= 0),
  -- salinan angka saat lunas (pengaturan pajak/service boleh berubah kemudian)
  subtotal_idr int4, service_pct numeric(5,2), service_idr int4, tax_pct numeric(5,2), tax_idr int4, total_idr int4,
  paid_at timestamptz, paid_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz, closed_by uuid references auth.users(id) on delete set null, close_reason text check (char_length(close_reason) <= 200),
  merged_into uuid references public.bills(id) on delete set null,
  unique (tenant_id, bill_no),
  unique (tenant_id, id)
);
create index if not exists bills_terbuka on public.bills(tenant_id, status, opened_at desc);

create table if not exists public.bill_tables (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  table_id uuid,
  table_label text not null,
  is_open boolean not null default true,
  foreign key (tenant_id, bill_id) references public.bills(tenant_id, id) on delete cascade,
  foreign key (tenant_id, table_id) references public.restaurant_tables(tenant_id, id) on delete set null (table_id)
);
create unique index if not exists bill_tables_satu_terbuka on public.bill_tables(table_id) where is_open and table_id is not null;
create index if not exists bill_tables_bill on public.bill_tables(bill_id);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  method text not null check (method in ('cash', 'card', 'qris', 'other')),
  amount_idr int4 not null check (amount_idr > 0),          -- bagian tagihan yang dilunasi metode ini
  tendered_idr int4 check (tendered_idr is null or tendered_idr >= amount_idr),   -- uang diterima (tunai) → kembalian
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  voided_at timestamptz,                                    -- diisi saat pembayaran dibatalkan
  foreign key (tenant_id, bill_id) references public.bills(tenant_id, id) on delete restrict
);
create index if not exists payments_bill on public.payments(bill_id);

alter table public.orders add column if not exists bill_id uuid;
alter table public.orders add column if not exists client_id text check (client_id is null or client_id ~ '^[0-9a-f]{32}$');
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_bill_fk') then
    alter table public.orders add constraint orders_bill_fk foreign key (tenant_id, bill_id) references public.bills(tenant_id, id) on delete restrict;
  end if;
end $$;
create index if not exists orders_bill on public.orders(bill_id);
create index if not exists orders_perangkat on public.orders(table_id, client_id, created_at desc);

-- =====================================================================
-- 2. FUNGSI DALAM
-- =====================================================================
create or replace function public._next_bill_no(p_tenant uuid) returns int language plpgsql security definer set search_path = public as $$
declare v int;
begin
  insert into public.order_counters (tenant_id, last_no, last_bill_no) values (p_tenant, 0, 1)
    on conflict (tenant_id) do update set last_bill_no = public.order_counters.last_bill_no + 1 returning last_bill_no into v;
  return v;
end $$;

-- Angka tagihan. Terbuka: dihitung dari pesanan non-batal + pengaturan pajak/service saat ini. Lunas: salinan yang tersimpan.
-- Urutan: subtotal − diskon → + biaya layanan → + pajak (dibulatkan ke rupiah).
create or replace function public._bill_figures(p_bill uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b public.bills; t public.tenants; v_sub int; v_disc int; v_base int; v_svc int; v_tax int;
begin
  select * into b from public.bills where id = p_bill;
  if not found then return null; end if;
  if b.status = 'paid' then
    return jsonb_build_object('subtotal', b.subtotal_idr, 'discount', b.discount_idr, 'service_pct', b.service_pct, 'service', b.service_idr, 'tax_pct', b.tax_pct, 'tax', b.tax_idr, 'total', b.total_idr);
  end if;
  select * into t from public.tenants where id = b.tenant_id;
  select coalesce(sum(total_idr), 0)::int into v_sub from public.orders where bill_id = p_bill and status <> 'cancelled';
  v_disc := least(b.discount_idr, v_sub);
  v_base := v_sub - v_disc;
  v_svc := round(v_base * t.service_pct / 100.0)::int;
  v_tax := round((v_base + v_svc) * t.tax_pct / 100.0)::int;
  return jsonb_build_object('subtotal', v_sub, 'discount', v_disc, 'service_pct', t.service_pct, 'service', v_svc, 'tax_pct', t.tax_pct, 'tax', v_tax, 'total', v_base + v_svc + v_tax);
end $$;

-- Tagihan terbuka baru untuk sekumpulan meja (dipanggil di bawah kunci baris meja).
create or replace function public._open_bill(p_tenant uuid, p_tables uuid[]) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.bills (tenant_id, bill_no) values (p_tenant, public._next_bill_no(p_tenant)) returning id into v_id;
  insert into public.bill_tables (bill_id, tenant_id, table_id, table_label)
    select v_id, p_tenant, t.id, t.label from public.restaurant_tables t where t.tenant_id = p_tenant and t.id = any (p_tables);
  return v_id;
end $$;

revoke all on function public._next_bill_no(uuid), public._bill_figures(uuid), public._open_bill(uuid, uuid[]) from public, anon, authenticated;

-- =====================================================================
-- 3. PEMICU PENJAGA
-- =====================================================================
create or replace function public.guard_table_delete() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.bill_tables where table_id = old.id and is_open) then
    raise exception 'Meja ini masih punya tagihan terbuka. Selesaikan atau tutup tagihannya dulu.' using errcode = 'check_violation';
  end if;
  return old;
end $$;
drop trigger if exists restaurant_tables_guard on public.restaurant_tables;
create trigger restaurant_tables_guard before delete on public.restaurant_tables for each row execute function public.guard_table_delete();

-- =====================================================================
-- 4. DATA LAMA → TAGIHAN (sekali; hanya pesanan yang belum punya tagihan)
-- =====================================================================
do $$
declare r record; v_bill uuid; v_no int;
begin
  -- (a) pesanan belum dibayar & tidak batal, per meja → satu tagihan TERBUKA per meja
  for r in select tenant_id, table_id, min(table_label) as label, min(created_at) as first_at from public.orders
            where bill_id is null and payment_status = 'unpaid' and status <> 'cancelled' and table_id is not null group by tenant_id, table_id loop
    v_no := public._next_bill_no(r.tenant_id);
    insert into public.bills (tenant_id, bill_no, opened_at) values (r.tenant_id, v_no, r.first_at) returning id into v_bill;
    insert into public.bill_tables (bill_id, tenant_id, table_id, table_label) values (v_bill, r.tenant_id, r.table_id, r.label);
    update public.orders set bill_id = v_bill where tenant_id = r.tenant_id and table_id = r.table_id and bill_id is null and payment_status = 'unpaid' and status <> 'cancelled';
  end loop;
  -- (b) sisanya: satu tagihan tertutup per pesanan (lunas → paid + pembayaran; selain itu → void)
  for r in select * from public.orders where bill_id is null order by created_at loop
    v_no := public._next_bill_no(r.tenant_id);
    if r.payment_status = 'paid' then
      insert into public.bills (tenant_id, bill_no, status, label, opened_at, subtotal_idr, discount_idr, service_pct, service_idr, tax_pct, tax_idr, total_idr, paid_at, paid_by, closed_at)
        values (r.tenant_id, v_no, 'paid', r.table_label, r.created_at, r.total_idr, 0, 0, 0, 0, 0, r.total_idr, r.paid_at, r.paid_by, r.paid_at) returning id into v_bill;
      insert into public.payments (bill_id, tenant_id, method, amount_idr, created_by, created_at) values (v_bill, r.tenant_id, r.payment_method, greatest(r.total_idr, 1), r.paid_by, coalesce(r.paid_at, r.created_at));
    else
      insert into public.bills (tenant_id, bill_no, status, label, opened_at, closed_at, close_reason)
        values (r.tenant_id, v_no, 'void', r.table_label, r.created_at, r.created_at, 'migrasi: pesanan lama tanpa pembayaran') returning id into v_bill;
    end if;
    update public.orders set bill_id = v_bill where id = r.id;
  end loop;
end $$;

-- =====================================================================
-- 5. PESANAN PELANGGAN (publik: dipanggil server dengan kunci anon)
-- =====================================================================
-- Galat: E:invalid_table | E:closed | E:empty | E:rate_limited (1 pesanan / 10 dtk / perangkat) | E:table_full (maks 15 pelanggan / meja) | E:item_unavailable
drop function if exists public.place_order(uuid, text, jsonb, text, text, text);
create or replace function public.place_order(p_tenant uuid, p_token text, p_items jsonb, p_name text, p_note text, p_lang text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table public.restaurant_tables; v_bill public.bills; v_bid uuid; v_primary text; v_lang text; v_no int; v_order uuid; v_total int; v_req int; v_ok int; v_n int; v_i int;
        v_client text := case when p_client ~ '^[0-9a-f]{32}$' then lower(p_client) else null end; v_mine int;
begin
  select * into v_table from public.restaurant_tables where tenant_id = p_tenant and token = p_token and is_active for update;   -- kunci meja: pesanan serempak diproses berurutan
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_table'; end if;
  if not public.orders_open(p_tenant) then raise exception 'E:closed'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then raise exception 'E:empty'; end if;
  if v_client is not null and exists (select 1 from public.orders where table_id = v_table.id and client_id = v_client and created_at > now() - interval '10 seconds') then raise exception 'E:rate_limited'; end if;

  -- tagihan terbuka untuk meja ini (atau buka baru)
  for v_i in 1..3 loop
    select b.id into v_bid from public.bills b join public.bill_tables bt on bt.bill_id = b.id where bt.table_id = v_table.id and bt.is_open and b.status = 'open' limit 1;
    if v_bid is null then
      v_bid := public._open_bill(p_tenant, array[v_table.id]); select * into v_bill from public.bills where id = v_bid; exit;
    end if;
    select * into v_bill from public.bills where id = v_bid for update;
    exit when v_bill.status = 'open' and exists (select 1 from public.bill_tables where bill_id = v_bill.id and table_id = v_table.id and is_open);
    v_bill := null; v_bid := null;   -- digabung/ditutup saat menunggu kunci → ulangi
  end loop;
  if v_bill.id is null then raise exception 'E:unavailable'; end if;

  -- batas pelanggan per meja (perangkat dikenali lewat client_id; tanpa client_id dihitung per pesanan)
  select count(distinct coalesce(client_id, id::text)) into v_n from public.orders where bill_id = v_bill.id and table_id = v_table.id;
  if v_n >= 15 and (v_client is null or not exists (select 1 from public.orders where bill_id = v_bill.id and table_id = v_table.id and client_id = v_client)) then
    raise exception 'E:table_full';
  end if;

  select lang into v_primary from public.tenant_languages where tenant_id = p_tenant and position = 1;
  v_primary := coalesce(v_primary, 'id');
  v_lang := case when p_lang is not null and exists (select 1 from public.tenant_languages where tenant_id = p_tenant and lang = p_lang) then p_lang else v_primary end;

  create temporary table _req on commit drop as
    select (e->>'id')::uuid as id, sum(least(greatest(coalesce((e->>'qty')::int, 1), 1), 20))::int as qty from jsonb_array_elements(p_items) e group by 1;
  create temporary table _ok on commit drop as
    select m.id, m.price_idr, r.qty, coalesce(t1.name, t2.name, '?') as name
      from _req r join public.menu_items m on m.id = r.id and m.tenant_id = p_tenant and m.is_visible and m.archived_at is null and not m.is_sold_out
      left join public.menu_item_translations t1 on t1.menu_item_id = m.id and t1.lang = v_lang
      left join public.menu_item_translations t2 on t2.menu_item_id = m.id and t2.lang = v_primary;
  select count(*) into v_req from _req; select count(*), coalesce(sum(price_idr * qty), 0) into v_ok, v_total from _ok;
  if v_ok = 0 or v_ok <> v_req then drop table _req, _ok; raise exception 'E:item_unavailable'; end if;

  insert into public.order_counters (tenant_id, last_no) values (p_tenant, 1)
    on conflict (tenant_id) do update set last_no = public.order_counters.last_no + 1 returning last_no into v_no;
  insert into public.orders (tenant_id, table_id, table_label, order_no, customer_name, note, total_idr, lang, bill_id, client_id)
    values (p_tenant, v_table.id, v_table.label, lpad(v_no::text, 4, '0'), left(nullif(btrim(p_name), ''), 60), left(nullif(btrim(p_note), ''), 200), v_total, v_lang, v_bill.id, v_client)
    returning id into v_order;
  insert into public.order_items (order_id, tenant_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total)
    select v_order, p_tenant, id, name, price_idr, qty, price_idr * qty from _ok;
  drop table _req, _ok;
  select coalesce(sum(total_idr), 0)::int into v_mine from public.orders where bill_id = v_bill.id and status <> 'cancelled' and v_client is not null and client_id = v_client;
  return jsonb_build_object('order_no', lpad(v_no::text, 4, '0'), 'total_idr', v_total, 'table_label', v_table.label, 'my_total_idr', v_mine);
end $$;

-- Pelanggan menekan "Minta bill". Idempotent. Galat: E:invalid_table | E:no_bill (belum ada pesanan di meja ini)
create or replace function public.request_bill(p_tenant uuid, p_token text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table public.restaurant_tables; v_bill public.bills; v_client text := case when p_client ~ '^[0-9a-f]{32}$' then lower(p_client) else null end; v_mine int; t public.tenants;
begin
  select * into v_table from public.restaurant_tables where tenant_id = p_tenant and token = p_token and is_active;
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_table'; end if;
  select b.* into v_bill from public.bills b join public.bill_tables bt on bt.bill_id = b.id
   where bt.table_id = v_table.id and bt.is_open and b.status = 'open' limit 1 for update of b;
  if not found or not exists (select 1 from public.orders where bill_id = v_bill.id and status <> 'cancelled') then raise exception 'E:no_bill'; end if;
  update public.bills set bill_requested_at = coalesce(bill_requested_at, now()), bill_requested_label = coalesce(bill_requested_label, v_table.label) where id = v_bill.id;
  select coalesce(sum(total_idr), 0)::int into v_mine from public.orders where bill_id = v_bill.id and status <> 'cancelled' and v_client is not null and client_id = v_client;
  select * into t from public.tenants where id = p_tenant;
  return jsonb_build_object('table_label', v_table.label, 'my_total_idr', v_mine, 'has_fees', (t.tax_pct > 0 or t.service_pct > 0));
end $$;

-- =====================================================================
-- 6. KASIR / MANAGER / OWNER
-- =====================================================================
-- Daftar tagihan lengkap dengan angka, pesanan per pelanggan, dan pembayaran.
-- p_scope: 'open' = tagihan terbuka | 'closed' = tagihan tertutup HARI INI (zona waktu restoran)
create or replace function public.list_bills(p_tenant uuid, p_scope text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_out jsonb;
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  v_from := (public.tenant_today(p_tenant)::timestamp at time zone coalesce((select timezone from public.tenants where id = p_tenant), 'Asia/Jakarta'));
  select coalesce(jsonb_agg(x order by (x->>'sort_at') desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'id', b.id, 'bill_no', b.bill_no, 'status', b.status, 'label', b.label, 'opened_at', b.opened_at, 'closed_at', b.closed_at, 'paid_at', b.paid_at,
      'close_reason', b.close_reason, 'sort_at', coalesce(b.closed_at, b.opened_at), 'discount_idr', b.discount_idr,
      'requested_at', b.bill_requested_at, 'requested_label', b.bill_requested_label,
      'tables', coalesce((select jsonb_agg(jsonb_build_object('id', bt.table_id, 'label', bt.table_label) order by bt.table_label) from public.bill_tables bt where bt.bill_id = b.id), '[]'::jsonb),
      'figures', public._bill_figures(b.id),
      'orders', coalesce((select jsonb_agg(jsonb_build_object(
          'id', o.id, 'order_no', o.order_no, 'table_label', o.table_label, 'customer_name', o.customer_name, 'client_id', o.client_id, 'status', o.status,
          'total_idr', o.total_idr, 'note', o.note, 'created_at', o.created_at,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'qty', i.qty, 'line_total', i.line_total) order by i.name_snapshot) from public.order_items i where i.order_id = o.id), '[]'::jsonb)
        ) order by o.created_at) from public.orders o where o.bill_id = b.id), '[]'::jsonb),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.method, 'amount_idr', p.amount_idr, 'tendered_idr', p.tendered_idr) order by p.created_at) from public.payments p where p.bill_id = b.id and p.voided_at is null), '[]'::jsonb)
    ) as x
    from public.bills b
    where b.tenant_id = p_tenant
      and ((p_scope = 'open' and b.status = 'open') or (p_scope = 'closed' and b.status in ('paid', 'void') and coalesce(b.closed_at, b.paid_at) >= v_from))
    order by coalesce(b.closed_at, b.opened_at) desc limit 200
  ) s;
  return v_out;
end $$;

-- Penanda "minta bill" (untuk semua staf yang membantu di lantai, termasuk Service — tanpa nominal)
create or replace function public.list_bill_requests(p_tenant uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier', 'service']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('bill_id', b.id, 'label', coalesce(b.bill_requested_label, b.label, '#' || b.bill_no), 'at', b.bill_requested_at) order by b.bill_requested_at)
                     from public.bills b where b.tenant_id = p_tenant and b.status = 'open' and b.bill_requested_at is not null), '[]'::jsonb);
end $$;

-- Gabungkan 2+ meja ke satu tagihan. Meja yang sudah punya tagihan: tagihannya dilebur (diskon dijumlahkan). Meja kosong: ikut bergabung.
create or replace function public.merge_tables(p_tenant uuid, p_tables uuid[]) returns uuid language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_target uuid; v_src uuid; v_disc int; v_req timestamptz; v_reqlabel text;
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  select array_agg(distinct x) into p_tables from unnest(p_tables) x;
  if p_tables is null or cardinality(p_tables) < 2 then raise exception 'Pilih minimal 2 meja' using errcode = 'check_violation'; end if;
  perform 1 from public.restaurant_tables where tenant_id = p_tenant and id = any (p_tables) order by id for update;
  if (select count(*) from public.restaurant_tables where tenant_id = p_tenant and id = any (p_tables)) <> cardinality(p_tables) then raise exception 'Meja tidak ditemukan' using errcode = 'check_violation'; end if;

  select array_agg(id order by opened_at, id) into v_ids from (
    select distinct b.id, b.opened_at from public.bills b join public.bill_tables bt on bt.bill_id = b.id
     where b.tenant_id = p_tenant and b.status = 'open' and bt.is_open and bt.table_id = any (p_tables)) s;
  if v_ids is null then
    v_target := public._open_bill(p_tenant, p_tables);
  else
    perform 1 from public.bills where id = any (v_ids) order by id for update;
    v_target := v_ids[1];
    select coalesce(sum(discount_idr), 0)::int, min(bill_requested_at) into v_disc, v_req from public.bills where id = any (v_ids);
    select bill_requested_label into v_reqlabel from public.bills where id = any (v_ids) and bill_requested_at is not null order by bill_requested_at limit 1;
    foreach v_src in array v_ids loop
      if v_src <> v_target then
        update public.bill_tables set bill_id = v_target where bill_id = v_src;
        update public.orders set bill_id = v_target where bill_id = v_src;
        update public.bills set status = 'merged', merged_into = v_target, closed_at = now(), closed_by = auth.uid() where id = v_src;
      end if;
    end loop;
    update public.bills set discount_idr = v_disc, bill_requested_at = v_req, bill_requested_label = v_reqlabel where id = v_target;
    insert into public.bill_tables (bill_id, tenant_id, table_id, table_label)
      select v_target, p_tenant, t.id, t.label from public.restaurant_tables t
       where t.tenant_id = p_tenant and t.id = any (p_tables) and not exists (select 1 from public.bill_tables bt where bt.table_id = t.id and bt.is_open);
  end if;
  return v_target;
end $$;

-- Pisahkan pesanan terpilih ke tagihan baru (mis. satu pelanggan ingin bayar sendiri). Tagihan baru tidak terikat meja.
create or replace function public.split_orders(p_orders uuid[]) returns uuid language plpgsql security definer set search_path = public as $$
declare v_bills uuid[]; v_b public.bills; v_new uuid; v_n int;
begin
  select array_agg(distinct bill_id) into v_bills from public.orders where id = any (p_orders);
  if v_bills is null or cardinality(v_bills) <> 1 or (select count(*) from public.orders where id = any (p_orders)) <> cardinality(p_orders) then
    raise exception 'Pilih pesanan dari satu tagihan yang sama' using errcode = 'check_violation'; end if;
  select * into v_b from public.bills where id = v_bills[1] for update;
  if not public.has_role(v_b.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if v_b.status <> 'open' then raise exception 'Tagihan sudah ditutup' using errcode = 'check_violation'; end if;
  select count(*) into v_n from public.orders where bill_id = v_b.id and status <> 'cancelled' and id <> all (p_orders);
  if v_n = 0 then raise exception 'Sisakan minimal satu pesanan di tagihan asal' using errcode = 'check_violation'; end if;
  insert into public.bills (tenant_id, bill_no, label) values (v_b.tenant_id, public._next_bill_no(v_b.tenant_id), 'Pisahan dari #' || lpad(v_b.bill_no::text, 4, '0')) returning id into v_new;
  update public.orders set bill_id = v_new where id = any (p_orders);
  return v_new;
end $$;

create or replace function public.set_bill_discount(p_bill uuid, p_amount int) returns void language plpgsql security definer set search_path = public as $$
declare b public.bills; v_sub int;
begin
  select * into b from public.bills where id = p_bill for update;
  if not found or not public.has_role(b.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if b.status <> 'open' then raise exception 'Tagihan sudah ditutup' using errcode = 'check_violation'; end if;
  select coalesce(sum(total_idr), 0)::int into v_sub from public.orders where bill_id = b.id and status <> 'cancelled';
  if p_amount is null or p_amount < 0 or p_amount > v_sub then raise exception 'Diskon harus antara 0 dan subtotal (Rp %)', v_sub using errcode = 'check_violation'; end if;
  update public.bills set discount_idr = p_amount where id = b.id;
end $$;

-- Bayar tagihan SEKALI. p_payments = [{method: cash|card|qris|other, amount, tendered?}] — jumlah amount harus = total (tidak dicicil).
create or replace function public.pay_bill(p_bill uuid, p_payments jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bills; f jsonb; v_total int; v_sum int := 0; v_change int := 0; x jsonb; v_m text; v_a int; v_t int; v_methods text[] := '{}';
begin
  select * into b from public.bills where id = p_bill for update;
  if not found or not public.has_role(b.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if b.status <> 'open' then raise exception 'Tagihan sudah ditutup' using errcode = 'check_violation'; end if;
  if not exists (select 1 from public.orders where bill_id = b.id and status <> 'cancelled') then raise exception 'Tagihan kosong: tidak ada pesanan yang aktif' using errcode = 'check_violation'; end if;
  if p_payments is null or jsonb_typeof(p_payments) <> 'array' or jsonb_array_length(p_payments) not between 1 and 6 then raise exception 'Isi 1–6 baris pembayaran' using errcode = 'check_violation'; end if;
  f := public._bill_figures(b.id); v_total := (f->>'total')::int;
  for x in select * from jsonb_array_elements(p_payments) loop
    v_m := x->>'method';
    if v_m is null or v_m not in ('cash', 'card', 'qris', 'other') then raise exception 'Metode pembayaran tidak valid' using errcode = 'check_violation'; end if;
    if coalesce(x->>'amount', '') !~ '^[0-9]{1,9}$' or (x->>'amount')::int < 1 then raise exception 'Nominal pembayaran tidak valid' using errcode = 'check_violation'; end if;
    v_a := (x->>'amount')::int;
    v_t := null;
    if v_m = 'cash' then
      v_t := case when coalesce(x->>'tendered', '') = '' then v_a when x->>'tendered' ~ '^[0-9]{1,9}$' then (x->>'tendered')::int else null end;
      if v_t is null or v_t < v_a then raise exception 'Uang diterima kurang dari nominal tunai' using errcode = 'check_violation'; end if;
      v_change := v_change + (v_t - v_a);
    end if;
    insert into public.payments (bill_id, tenant_id, method, amount_idr, tendered_idr, created_by) values (b.id, b.tenant_id, v_m, v_a, v_t, auth.uid());
    v_sum := v_sum + v_a; v_methods := v_methods || v_m;
  end loop;
  if v_sum <> v_total then raise exception 'Jumlah pembayaran (Rp %) harus sama dengan total tagihan (Rp %)', v_sum, v_total using errcode = 'check_violation'; end if;
  update public.bills set status = 'paid', subtotal_idr = (f->>'subtotal')::int, discount_idr = (f->>'discount')::int,
         service_pct = (f->>'service_pct')::numeric, service_idr = (f->>'service')::int, tax_pct = (f->>'tax_pct')::numeric, tax_idr = (f->>'tax')::int, total_idr = v_total,
         paid_at = now(), paid_by = auth.uid(), closed_at = now(), closed_by = auth.uid() where id = b.id;
  update public.bill_tables set is_open = false where bill_id = b.id;
  update public.orders set payment_status = 'paid', payment_method = case when (select count(distinct m) from unnest(v_methods) m) = 1 then v_methods[1] else 'other' end,
         paid_at = now(), paid_by = auth.uid() where bill_id = b.id and status <> 'cancelled';
  return jsonb_build_object('total', v_total, 'change', v_change);
end $$;

-- Tutup paksa tagihan terbuka tanpa pembayaran (mis. pelanggan pergi / salah buka). Hanya Manager & Owner.
create or replace function public.void_bill(p_bill uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare b public.bills;
begin
  select * into b from public.bills where id = p_bill for update;
  if not found or not public.has_role(b.tenant_id, array['owner', 'manager']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if b.status <> 'open' then raise exception 'Hanya tagihan terbuka yang bisa ditutup paksa' using errcode = 'check_violation'; end if;
  update public.bills set status = 'void', closed_at = now(), closed_by = auth.uid(), close_reason = left(nullif(btrim(p_reason), ''), 200) where id = b.id;
  update public.bill_tables set is_open = false where bill_id = b.id;
end $$;

-- Batalkan pembayaran: tagihan lunas dibuka lagi (pembayaran lama ditandai batal). Hanya Manager & Owner.
create or replace function public.reopen_bill(p_bill uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare b public.bills;
begin
  select * into b from public.bills where id = p_bill for update;
  if not found or not public.has_role(b.tenant_id, array['owner', 'manager']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if b.status <> 'paid' then raise exception 'Hanya tagihan lunas yang bisa dibatalkan pembayarannya' using errcode = 'check_violation'; end if;
  if exists (select 1 from public.bill_tables bt where bt.bill_id = b.id and bt.table_id is not null
              and exists (select 1 from public.bill_tables o where o.table_id = bt.table_id and o.is_open)) then
    raise exception 'Salah satu meja sudah punya tagihan terbuka baru. Tutup atau gabungkan dulu.' using errcode = 'check_violation'; end if;
  update public.payments set voided_at = now() where bill_id = b.id and voided_at is null;
  update public.orders set payment_status = 'unpaid', payment_method = null, paid_at = null, paid_by = null where bill_id = b.id;
  update public.bill_tables set is_open = true where bill_id = b.id and table_id is not null;
  update public.bills set status = 'open', paid_at = null, paid_by = null, closed_at = null, closed_by = null, close_reason = left(nullif(btrim(p_reason), ''), 200),
         subtotal_idr = null, service_pct = null, service_idr = null, tax_pct = null, tax_idr = null, total_idr = null where id = b.id;
end $$;

-- Pajak & biaya layanan (persen). Hanya Owner (dan Super Admin).
create or replace function public.set_tenant_billing(p_tenant uuid, p_tax numeric, p_service numeric) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_tax is null or p_service is null or p_tax not between 0 and 100 or p_service not between 0 and 100 then raise exception 'Persentase harus antara 0 dan 100' using errcode = 'check_violation'; end if;
  update public.tenants set tax_pct = round(p_tax, 2), service_pct = round(p_service, 2) where id = p_tenant;
end $$;

-- Pembayaran kini hanya lewat tagihan. Fungsi lama ditutup supaya tidak ada jalur ganda.
create or replace function public.set_order_payment(p_order uuid, p_method text) returns void language plpgsql security definer set search_path = public as $$
begin raise exception 'Pembayaran dicatat lewat tab Tagihan' using errcode = '0A000'; end $$;

-- Pesanan pada tagihan yang sudah dibayar/ditutup tidak boleh dibatalkan atau dibuka lagi (angka tagihan akan berubah). Selebihnya sama seperti sebelumnya.
create or replace function public.set_order_status(p_order uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_old text; v_role text; v_ok boolean; v_bill_status text;
begin
  if p_status not in ('new', 'preparing', 'ready', 'done', 'cancelled') then raise exception 'Status tidak valid' using errcode = 'check_violation'; end if;
  select o.tenant_id, o.status, b.status into v_tenant, v_old, v_bill_status from public.orders o left join public.bills b on b.id = o.bill_id where o.id = p_order;
  v_role := public.tenant_role(v_tenant);
  v_ok := case when v_role in ('super_admin', 'owner', 'manager', 'cashier') then true
               when v_role = 'kitchen' then p_status in ('preparing', 'ready') and v_old in ('new', 'preparing')
               when v_role = 'service' then p_status = 'done' and v_old = 'ready'
               else false end;
  if v_tenant is null or not v_ok then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if (p_status = 'cancelled' or v_old = 'cancelled') and v_bill_status is not null and v_bill_status <> 'open' then
    raise exception 'Tagihan pesanan ini sudah ditutup. Batalkan pembayarannya dulu (Manager/Owner).' using errcode = 'check_violation'; end if;
  update public.orders set status = p_status where id = p_order;
end $$;

-- =====================================================================
-- 7. AKSES (RLS) — angka uang hanya untuk owner/manager/cashier
-- =====================================================================
alter table public.bills enable row level security;
alter table public.bill_tables enable row level security;
alter table public.payments enable row level security;
drop policy if exists "baca tagihan" on public.bills;
create policy "baca tagihan" on public.bills for select to authenticated using (public.has_role(tenant_id, array['owner', 'manager', 'cashier']));
drop policy if exists "baca meja tagihan" on public.bill_tables;
create policy "baca meja tagihan" on public.bill_tables for select to authenticated using (public.has_role(tenant_id, array['owner', 'manager', 'cashier']));
drop policy if exists "baca pembayaran" on public.payments;
create policy "baca pembayaran" on public.payments for select to authenticated using (public.has_role(tenant_id, array['owner', 'manager', 'cashier']));

-- Fungsi admin hanya untuk pengguna login; fungsi pelanggan (place_order, request_bill) dipanggil server dengan kunci anon.
revoke execute on function public.list_bills(uuid, text), public.list_bill_requests(uuid), public.merge_tables(uuid, uuid[]), public.split_orders(uuid[]),
  public.set_bill_discount(uuid, int), public.pay_bill(uuid, jsonb), public.void_bill(uuid, text), public.reopen_bill(uuid, text), public.set_tenant_billing(uuid, numeric, numeric)
  from public, anon;
grant execute on function public.list_bills(uuid, text), public.list_bill_requests(uuid), public.merge_tables(uuid, uuid[]), public.split_orders(uuid[]),
  public.set_bill_discount(uuid, int), public.pay_bill(uuid, jsonb), public.void_bill(uuid, text), public.reopen_bill(uuid, text), public.set_tenant_billing(uuid, numeric, numeric)
  to authenticated;
