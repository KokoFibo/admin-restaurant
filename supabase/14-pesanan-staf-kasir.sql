-- 14-pesanan-staf-kasir.sql — QR KASIR (take away di tempat), PESANAN OLEH STAF, dan NAMA ISTILAH/TOMBOL yang bisa diubah Owner.
-- Jalankan SETELAH 01…13. Aman diulang (idempotent). Hanya menambah; tidak menghapus data.
--
-- 1. QR Kasir: baris restaurant_tables dengan kind='counter' (maks satu per restoran). Pelanggan memindai QR di kasir → halaman Order biasa, tetapi
--    nama WAJIB, tiap pesanan menjadi TAGIHAN SENDIRI ("Take away #nomor · Nama", tanpa meja) dan langsung masuk dapur. Tanpa batas 15 pelanggan/meja; batas 10 dtk/perangkat tetap.
-- 2. Pesanan staf (Service/Cashier/Manager/Owner): place_staff_order — masuk ke tagihan terbuka meja itu (atau tagihan baru), langsung ke dapur, tanpa batas
--    10 dtk/15 pelanggan, tetap bisa saat "Tutup sementara". Untuk Kasir selalu tagihan baru (nama wajib).
-- 3. Nama istilah & tombol: tenant_labels. Teks untuk pelanggan per bahasa (takeaway, online_link, send_order, i_paid); teks untuk staf satu saja (lang='*').
--    Kosong = teks bawaan di kode. Label tagihan/pesanan yang sudah tersimpan TIDAK berubah (salinan saat dibuat).

-- =====================================================================
-- 1. KOLOM
-- =====================================================================
alter table public.restaurant_tables add column if not exists kind text not null default 'table' check (kind in ('table', 'counter'));
create unique index if not exists restaurant_tables_satu_kasir on public.restaurant_tables(tenant_id) where kind = 'counter';

alter table public.orders add column if not exists placed_by uuid references auth.users(id) on delete set null;     -- staf yang menginput (source='staff')
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'orders_source_check' and conrelid = 'public.orders'::regclass) then
    alter table public.orders drop constraint orders_source_check;
  end if;
  alter table public.orders add constraint orders_source_check check (source in ('dine_in', 'online', 'staff'));
end $$;

-- =====================================================================
-- 2. NAMA ISTILAH & TOMBOL
-- =====================================================================
create table if not exists public.tenant_labels (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  key text not null check (key in ('takeaway', 'online_link', 'send_order', 'i_paid', 'new_order', 'accept', 'reject', 'payment_received', 'notify_customer', 'add_counter_qr')),
  lang text not null check (lang ~ '^([a-z]{2}|\*)$'),
  text text not null check (char_length(btrim(text)) between 1 and 40),
  primary key (tenant_id, key, lang),
  -- teks staf (satu untuk semua) memakai lang '*'; teks pelanggan memakai kode bahasa
  check ((key in ('new_order', 'accept', 'reject', 'payment_received', 'notify_customer', 'add_counter_qr')) = (lang = '*'))
);
alter table public.tenant_labels enable row level security;
drop policy if exists "baca nama istilah" on public.tenant_labels;
create policy "baca nama istilah" on public.tenant_labels for select to authenticated using (public.is_member(tenant_id));

-- Teks istilah (bahasa tertentu), atau bawaan.
create or replace function public._label(p_tenant uuid, p_key text, p_lang text, p_default text) returns text language sql stable security definer set search_path = public as $$
  select coalesce((select l.text from public.tenant_labels l where l.tenant_id = p_tenant and l.key = p_key and l.lang = p_lang), p_default)
$$;
revoke all on function public._label(uuid, text, text, text) from public, anon, authenticated;

-- Simpan semua nama istilah sekaligus (Owner). p_items = [{key, lang, text}, …]; teks kosong = hapus (kembali ke bawaan). Menggantikan seluruh isi restoran ini.
create or replace function public.set_labels(p_tenant uuid, p_items jsonb) returns void language plpgsql security definer set search_path = public as $$
declare v_primary text; v_new text;
begin
  if not public.has_role(p_tenant, array['owner']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 100 then raise exception 'Data tidak valid' using errcode = 'check_violation'; end if;
  delete from public.tenant_labels where tenant_id = p_tenant;
  insert into public.tenant_labels (tenant_id, key, lang, text)
    select p_tenant, e->>'key', e->>'lang', left(btrim(e->>'text'), 40) from jsonb_array_elements(p_items) e where btrim(coalesce(e->>'text', '')) <> '';
  -- nama QR Kasir mengikuti istilah "take away" (bahasa utama)
  select lang into v_primary from public.tenant_languages where tenant_id = p_tenant and position = 1; v_primary := coalesce(v_primary, 'id');
  v_new := public._label(p_tenant, 'takeaway', v_primary, 'Take away');
  begin
    update public.restaurant_tables set label = v_new where tenant_id = p_tenant and kind = 'counter' and label <> v_new;
  exception when unique_violation then raise exception 'Nama "%" sudah dipakai oleh meja lain. Ganti nama meja itu dulu atau pilih istilah lain.', v_new using errcode = 'check_violation';
  end;
end $$;

-- =====================================================================
-- 3. DATA PUBLIK: istilah untuk pelanggan, jenis meja
-- =====================================================================
create or replace function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select public.tenant_public_json_base(p_id) || (select jsonb_build_object('template_id', t.template_id, 'menu_display', t.menu_display,
           'online_enabled', t.online_enabled, 'online_prepay', t.online_enabled and t.online_prepay_enabled and t.qris_image_key is not null,
           'qris_image_key', case when t.online_enabled and t.online_prepay_enabled then t.qris_image_key end, 'pickup_note', t.pickup_note,
           'labels', coalesce((select jsonb_object_agg(k.key, k.m) from (select l.key, jsonb_object_agg(l.lang, l.text) as m from public.tenant_labels l where l.tenant_id = p_id and l.lang <> '*' group by l.key) k), '{}'::jsonb))
         from public.tenants t where t.id = p_id)
$$;

create or replace function public.resolve_table(p_tenant uuid, p_token text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('label', t.label, 'kind', t.kind) from public.restaurant_tables t
   where t.tenant_id = p_tenant and t.token = p_token and t.is_active and public.tenant_is_live(t.tenant_id)
$$;

-- =====================================================================
-- 4. PESANAN PELANGGAN (versi 09 + cabang QR Kasir)
-- =====================================================================
-- Kode galat: E:invalid_table | E:closed | E:empty | E:name_required | E:rate_limited | E:table_full | E:item_unavailable | E:unavailable
create or replace function public.place_order(p_tenant uuid, p_token text, p_items jsonb, p_name text, p_note text, p_lang text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table public.restaurant_tables; v_bill public.bills; v_bid uuid; v_primary text; v_lang text; v_no int; v_order uuid; v_total int; v_req int; v_ok int; v_n int; v_i int;
        v_client text := case when p_client ~ '^[0-9a-f]{32}$' then lower(p_client) else null end; v_mine int; v_name text := left(nullif(btrim(p_name), ''), 60);
begin
  select * into v_table from public.restaurant_tables where tenant_id = p_tenant and token = p_token and is_active for update;   -- kunci meja: pesanan serempak diproses berurutan
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_table'; end if;
  if not public.orders_open(p_tenant) then raise exception 'E:closed'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then raise exception 'E:empty'; end if;
  if v_table.kind = 'counter' and v_name is null then raise exception 'E:name_required'; end if;
  if v_client is not null and exists (select 1 from public.orders where table_id = v_table.id and client_id = v_client and created_at > now() - interval '10 seconds') then raise exception 'E:rate_limited'; end if;

  if v_table.kind = 'table' then
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
    values (p_tenant, v_table.id, v_table.label, lpad(v_no::text, 4, '0'), v_name, left(nullif(btrim(p_note), ''), 200), v_total, v_lang, v_bill.id, v_client)
    returning id into v_order;
  insert into public.order_items (order_id, tenant_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total)
    select v_order, p_tenant, id, name, price_idr, qty, price_idr * qty from _ok;
  drop table _req, _ok;
  if v_table.kind = 'counter' then
    -- QR Kasir: setiap pesanan = tagihan sendiri tanpa meja
    insert into public.bills (tenant_id, bill_no, label) values (p_tenant, public._next_bill_no(p_tenant), left(v_table.label || ' #' || lpad(v_no::text, 4, '0') || ' · ' || v_name, 80)) returning id into v_bid;
    update public.orders set bill_id = v_bid where id = v_order;
    v_mine := v_total;
  else
    select coalesce(sum(total_idr), 0)::int into v_mine from public.orders where bill_id = v_bill.id and status <> 'cancelled' and v_client is not null and client_id = v_client;
  end if;
  return jsonb_build_object('order_no', lpad(v_no::text, 4, '0'), 'total_idr', v_total, 'table_label', v_table.label, 'my_total_idr', v_mine, 'kind', v_table.kind);
end $$;

-- =====================================================================
-- 5. PESANAN OLEH STAF
-- =====================================================================
-- Meja yang bisa dipilih staf + penanda tagihan terbuka.
create or replace function public.list_staff_tables(p_tenant uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier', 'service']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label, 'kind', t.kind,
           'open_bill', exists (select 1 from public.bill_tables bt join public.bills b on b.id = bt.bill_id where bt.table_id = t.id and bt.is_open and b.status = 'open')) order by (t.kind = 'counter'), t.sort, t.label)
           from public.restaurant_tables t where t.tenant_id = p_tenant and t.is_active), '[]'::jsonb);
end $$;

-- Menu yang bisa dipesan staf (tampil, tidak diarsipkan; yang habis ditandai), nama dalam bahasa utama restoran.
create or replace function public.staff_menu(p_tenant uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_primary text;
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier', 'service']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  select lang into v_primary from public.tenant_languages where tenant_id = p_tenant and position = 1; v_primary := coalesce(v_primary, 'id');
  return jsonb_build_object(
    'cats', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', coalesce(ct.name, c.slug)) order by c.sort, c.slug)
               from public.categories c left join public.category_translations ct on ct.category_id = c.id and ct.lang = v_primary
              where c.tenant_id = p_tenant and c.is_visible), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'cat', m.category_id, 'name', coalesce(it.name, '?'), 'price', m.price_idr, 'sold_out', m.is_sold_out) order by m.sort, it.name)
               from public.menu_items m left join public.menu_item_translations it on it.menu_item_id = m.id and it.lang = v_primary
              where m.tenant_id = p_tenant and m.is_visible and m.archived_at is null), '[]'::jsonb));
end $$;

-- Pesanan baru oleh staf. Galat: Akses ditolak | E:invalid_table | E:empty | E:name_required | E:item_unavailable | E:unavailable
create or replace function public.place_staff_order(p_tenant uuid, p_table uuid, p_items jsonb, p_name text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table public.restaurant_tables; v_bill public.bills; v_bid uuid; v_primary text; v_no int; v_order uuid; v_total int; v_req int; v_ok int; v_i int; v_name text := left(nullif(btrim(p_name), ''), 60);
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier', 'service']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  select * into v_table from public.restaurant_tables where tenant_id = p_tenant and id = p_table and is_active for update;
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_table'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'E:empty'; end if;
  if v_table.kind = 'counter' and v_name is null then raise exception 'E:name_required'; end if;

  if v_table.kind = 'table' then
    for v_i in 1..3 loop
      select b.id into v_bid from public.bills b join public.bill_tables bt on bt.bill_id = b.id where bt.table_id = v_table.id and bt.is_open and b.status = 'open' limit 1;
      if v_bid is null then
        v_bid := public._open_bill(p_tenant, array[v_table.id]); select * into v_bill from public.bills where id = v_bid; exit;
      end if;
      select * into v_bill from public.bills where id = v_bid for update;
      exit when v_bill.status = 'open' and exists (select 1 from public.bill_tables where bill_id = v_bill.id and table_id = v_table.id and is_open);
      v_bill := null; v_bid := null;
    end loop;
    if v_bill.id is null then raise exception 'E:unavailable'; end if;
  end if;

  select lang into v_primary from public.tenant_languages where tenant_id = p_tenant and position = 1; v_primary := coalesce(v_primary, 'id');
  create temporary table _req on commit drop as
    select (e->>'id')::uuid as id, sum(least(greatest(coalesce((e->>'qty')::int, 1), 1), 99))::int as qty from jsonb_array_elements(p_items) e group by 1;
  create temporary table _ok on commit drop as
    select m.id, m.price_idr, r.qty, coalesce(t2.name, '?') as name
      from _req r join public.menu_items m on m.id = r.id and m.tenant_id = p_tenant and m.is_visible and m.archived_at is null and not m.is_sold_out
      left join public.menu_item_translations t2 on t2.menu_item_id = m.id and t2.lang = v_primary;
  select count(*) into v_req from _req; select count(*), coalesce(sum(price_idr * qty), 0) into v_ok, v_total from _ok;
  if v_ok = 0 or v_ok <> v_req then drop table _req, _ok; raise exception 'E:item_unavailable'; end if;

  insert into public.order_counters (tenant_id, last_no) values (p_tenant, 1)
    on conflict (tenant_id) do update set last_no = public.order_counters.last_no + 1 returning last_no into v_no;
  insert into public.orders (tenant_id, table_id, table_label, order_no, customer_name, note, total_idr, lang, bill_id, source, placed_by)
    values (p_tenant, v_table.id, v_table.label, lpad(v_no::text, 4, '0'), v_name, left(nullif(btrim(p_note), ''), 200), v_total, v_primary, v_bill.id, 'staff', auth.uid())
    returning id into v_order;
  insert into public.order_items (order_id, tenant_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total)
    select v_order, p_tenant, id, name, price_idr, qty, price_idr * qty from _ok;
  drop table _req, _ok;
  if v_table.kind = 'counter' then
    insert into public.bills (tenant_id, bill_no, label) values (p_tenant, public._next_bill_no(p_tenant), left(v_table.label || ' #' || lpad(v_no::text, 4, '0') || ' · ' || v_name, 80)) returning id into v_bid;
    update public.orders set bill_id = v_bid where id = v_order;
  end if;
  return jsonb_build_object('order_no', lpad(v_no::text, 4, '0'), 'table_label', v_table.label, 'total_idr', v_total, 'bill_id', v_bid, 'kind', v_table.kind);
end $$;

-- =====================================================================
-- 6. HAK EKSEKUSI
-- =====================================================================
revoke execute on function public.set_labels(uuid, jsonb), public.list_staff_tables(uuid), public.staff_menu(uuid), public.place_staff_order(uuid, uuid, jsonb, text, text) from public, anon;
grant execute on function public.set_labels(uuid, jsonb), public.list_staff_tables(uuid), public.staff_menu(uuid), public.place_staff_order(uuid, uuid, jsonb, text, text) to authenticated;
