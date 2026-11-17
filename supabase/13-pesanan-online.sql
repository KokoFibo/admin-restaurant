-- 13-pesanan-online.sql — PESANAN ONLINE (takeaway): pelanggan memesan lewat tautan (tanpa QR meja), staf mengonfirmasi, dapur memproses.
-- Jalankan SETELAH 01…12. Aman diulang (idempotent).
--
-- Alur
--   A. Bayar di tempat (utama):  pelanggan pesan → [pending] → staf Terima → [new → preparing → ready] → pelanggan ambil → kasir bayar di tab Tagihan → [done]
--   B. Bayar di muka QRIS (opsional, Owner yang mengaktifkan): pelanggan pesan → lihat QRIS → "Saya sudah bayar" → staf cek di aplikasi merchant →
--      "Pembayaran diterima" (tagihan lunas + masuk dapur) → [new → preparing → ready → done]
--   Tolak → [rejected] (dengan alasan). Tidak dikonfirmasi dalam 15 menit → [expired] (otomatis).
--
-- Keputusan desain
--   • Pesanan 'pending' BELUM punya tagihan. Tagihan ("Online #nomor · Nama", tanpa meja) dibuat saat staf menerima. Jadi tab Tagihan tidak berisi pesanan yang belum dikonfirmasi.
--   • Pesanan 'pending'/'rejected'/'expired' hanya terbaca oleh Owner/Manager/Cashier (RLS) — dapur dan Service tidak melihatnya.
--   • Nomor WhatsApp pelanggan di tabel terpisah (order_contacts), hanya terbaca Owner/Manager/Cashier, dihapus otomatis setelah 30 hari.
--   • Total untuk pelanggan online SUDAH termasuk biaya layanan dan pajak (pengaturan Owner yang sama dengan dine-in): QRIS statis menuntut nominal tepat.
--   • Anti-spam di DATABASE (kunci anon bersifat publik): 1 pesanan/60 dtk per perangkat & per nomor, maks 3 'pending' per perangkat/nomor, maks 30 'pending' per restoran.
--   • Kedaluwarsa 15 menit dijalankan "malas": saat pelanggan memuat status, saat staf memuat daftar, dan saat ada pesanan online baru.
--
-- Galat publik: E:online_off | E:closed | E:empty | E:name_required | E:phone_invalid | E:prepay_off | E:rate_limited | E:pending_full | E:item_unavailable | E:invalid_order

-- =====================================================================
-- 1. KOLOM & TABEL
-- =====================================================================
alter table public.tenants
  add column if not exists online_enabled boolean not null default false,
  add column if not exists online_prepay_enabled boolean not null default false,
  add column if not exists qris_image_key text check (qris_image_key is null or qris_image_key ~ '^restaurant/tenants/[a-z0-9-]+/qris/[a-z0-9-]+\.webp$'),
  add column if not exists pickup_note text check (pickup_note is null or char_length(pickup_note) <= 300);

alter table public.orders
  add column if not exists source text not null default 'dine_in' check (source in ('dine_in', 'online')),
  add column if not exists public_token text check (public_token is null or public_token ~ '^[0-9a-f]{32}$'),
  add column if not exists pickup_by text check (pickup_by is null or pickup_by in ('customer', 'courier')),
  add column if not exists pay_plan text check (pay_plan is null or pay_plan in ('at_pickup', 'prepay_qris')),
  add column if not exists pay_claimed_at timestamptz,
  add column if not exists reject_reason text check (reject_reason is null or char_length(reject_reason) <= 200),
  add column if not exists quote jsonb;     -- angka yang ditampilkan ke pelanggan saat memesan: {subtotal, service_pct, service, tax_pct, tax, total}
create unique index if not exists orders_public_token on public.orders(public_token) where public_token is not null;
create index if not exists orders_online_tertunda on public.orders(tenant_id, created_at) where source = 'online' and status = 'pending';
create index if not exists orders_online_perangkat on public.orders(tenant_id, client_id, created_at desc) where source = 'online';

-- status baru: pending (menunggu konfirmasi), rejected (ditolak), expired (tidak dikonfirmasi)
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'orders_status_check' and conrelid = 'public.orders'::regclass) then
    alter table public.orders drop constraint orders_status_check;
  end if;
  alter table public.orders add constraint orders_status_check check (status in ('pending', 'new', 'preparing', 'ready', 'done', 'cancelled', 'rejected', 'expired'));
end $$;

create table if not exists public.order_contacts (
  order_id uuid primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  phone text not null check (phone ~ '^[1-9][0-9]{7,14}$'),     -- angka saja, kode negara di depan (mis. 62812…)
  created_at timestamptz not null default now(),
  foreign key (tenant_id, order_id) references public.orders(tenant_id, id) on delete cascade
);
create index if not exists order_contacts_umur on public.order_contacts(tenant_id, created_at);
create index if not exists order_contacts_nomor on public.order_contacts(tenant_id, phone, created_at desc);
alter table public.order_contacts enable row level security;
drop policy if exists "baca kontak pesanan" on public.order_contacts;
create policy "baca kontak pesanan" on public.order_contacts for select to authenticated using (public.has_role(tenant_id, array['owner', 'manager', 'cashier']));

-- =====================================================================
-- 2. AKSES (RLS): dapur & Service tidak melihat pesanan yang belum dikonfirmasi / ditolak / kedaluwarsa
-- =====================================================================
create or replace function public.order_visible(p_tenant uuid, p_status text) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_member(p_tenant) and (p_status not in ('pending', 'rejected', 'expired') or public.has_role(p_tenant, array['owner', 'manager', 'cashier']))
$$;
drop policy if exists "baca pesanan sendiri" on public.orders;
create policy "baca pesanan sendiri" on public.orders for select to authenticated using (public.order_visible(tenant_id, status));
drop policy if exists "baca isi pesanan sendiri" on public.order_items;
create policy "baca isi pesanan sendiri" on public.order_items for select to authenticated
  using (public.is_member(tenant_id) and exists (select 1 from public.orders o where o.id = order_items.order_id and o.tenant_id = order_items.tenant_id and public.order_visible(o.tenant_id, o.status)));

-- =====================================================================
-- 3. FUNGSI DALAM
-- =====================================================================
-- Angka untuk pelanggan online: (subtotal) + biaya layanan, lalu pajak (pengaturan Owner saat ini). Pembulatan sama dengan _bill_figures.
create or replace function public._online_figures(p_tenant uuid, p_sub int) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.tenants; v_svc int; v_tax int;
begin
  select * into t from public.tenants where id = p_tenant;
  v_svc := round(p_sub * t.service_pct / 100.0)::int;
  v_tax := round((p_sub + v_svc) * t.tax_pct / 100.0)::int;
  return jsonb_build_object('subtotal', p_sub, 'service_pct', t.service_pct, 'service', v_svc, 'tax_pct', t.tax_pct, 'tax', v_tax, 'total', p_sub + v_svc + v_tax);
end $$;

-- Pesanan online 'pending' yang lewat 15 menit → 'expired'. Mengembalikan jumlah yang kedaluwarsa.
create or replace function public._expire_online(p_tenant uuid, p_order uuid default null) returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.orders set status = 'expired'
   where tenant_id = p_tenant and source = 'online' and status = 'pending' and created_at < now() - interval '15 minutes' and (p_order is null or id = p_order);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Buat tagihan tanpa meja untuk pesanan online dan kaitkan.
create or replace function public._open_online_bill(p_order public.orders) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.bills (tenant_id, bill_no, label)
    values (p_order.tenant_id, public._next_bill_no(p_order.tenant_id), left('Online #' || p_order.order_no || coalesce(' · ' || p_order.customer_name, ''), 80)) returning id into v_id;
  update public.orders set bill_id = v_id, status = 'new' where id = p_order.id;
  return v_id;
end $$;
revoke all on function public._online_figures(uuid, int), public._expire_online(uuid, uuid), public._open_online_bill(public.orders) from public, anon, authenticated;

-- =====================================================================
-- 4. PELANGGAN (publik; dipanggil server dengan kunci anon)
-- =====================================================================
create or replace function public.place_online_order(p_tenant uuid, p_items jsonb, p_name text, p_phone text, p_pickup_by text, p_pay_plan text, p_note text, p_lang text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.tenants; v_client text := case when p_client ~ '^[0-9a-f]{32}$' then lower(p_client) else null end;
        v_name text := left(nullif(btrim(p_name), ''), 60); v_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'); v_phone text;
        v_primary text; v_lang text; v_no int; v_order uuid; v_total int; v_req int; v_ok int; v_fig jsonb; v_token text := replace(gen_random_uuid()::text, '-', '');
        v_pickup text := case when p_pickup_by = 'courier' then 'courier' else 'customer' end; v_plan text := case when p_pay_plan = 'prepay_qris' then 'prepay_qris' else 'at_pickup' end;
begin
  select * into t from public.tenants where id = p_tenant;
  if not found or not public.tenant_is_live(p_tenant) or not t.online_enabled then raise exception 'E:online_off'; end if;
  if not public.orders_open(p_tenant) then raise exception 'E:closed'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then raise exception 'E:empty'; end if;
  if v_name is null then raise exception 'E:name_required'; end if;
  v_phone := case when v_digits ~ '^0' then '62' || substr(v_digits, 2) when v_digits ~ '^8' then '62' || v_digits else v_digits end;
  if v_phone !~ '^[1-9][0-9]{7,14}$' then raise exception 'E:phone_invalid'; end if;
  if v_plan = 'prepay_qris' and not (t.online_prepay_enabled and t.qris_image_key is not null) then raise exception 'E:prepay_off'; end if;

  perform pg_advisory_xact_lock(hashtextextended('online:' || p_tenant::text, 0));          -- pesanan online serempak diproses berurutan → batas tidak bisa dilewati
  perform public._expire_online(p_tenant);
  delete from public.order_contacts where tenant_id = p_tenant and created_at < now() - interval '30 days';   -- nomor WA dihapus otomatis setelah 30 hari

  -- batas anti-spam
  if exists (select 1 from public.orders o where o.tenant_id = p_tenant and o.source = 'online' and o.created_at > now() - interval '60 seconds'
               and ((v_client is not null and o.client_id = v_client) or exists (select 1 from public.order_contacts c where c.order_id = o.id and c.phone = v_phone))) then
    raise exception 'E:rate_limited';
  end if;
  if (select count(*) from public.orders o where o.tenant_id = p_tenant and o.source = 'online' and o.status = 'pending'
        and ((v_client is not null and o.client_id = v_client) or exists (select 1 from public.order_contacts c where c.order_id = o.id and c.phone = v_phone))) >= 3
     or (select count(*) from public.orders where tenant_id = p_tenant and source = 'online' and status = 'pending') >= 30 then
    raise exception 'E:pending_full';
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
  v_fig := public._online_figures(p_tenant, v_total);

  insert into public.order_counters (tenant_id, last_no) values (p_tenant, 1)
    on conflict (tenant_id) do update set last_no = public.order_counters.last_no + 1 returning last_no into v_no;
  insert into public.orders (tenant_id, table_id, table_label, order_no, mode, source, status, customer_name, note, total_idr, lang, client_id, public_token, pickup_by, pay_plan, quote)
    values (p_tenant, null, 'Online', lpad(v_no::text, 4, '0'), 'takeaway', 'online', 'pending', v_name, left(nullif(btrim(p_note), ''), 200), v_total, v_lang, v_client, v_token, v_pickup, v_plan, v_fig)
    returning id into v_order;
  insert into public.order_items (order_id, tenant_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total)
    select v_order, p_tenant, id, name, price_idr, qty, price_idr * qty from _ok;
  insert into public.order_contacts (order_id, tenant_id, phone) values (v_order, p_tenant, v_phone);
  drop table _req, _ok;
  return jsonb_build_object('order_no', lpad(v_no::text, 4, '0'), 'token', v_token, 'status', 'pending', 'pickup_by', v_pickup, 'pay_plan', v_plan, 'figures', v_fig, 'total_idr', (v_fig->>'total')::int);
end $$;

-- Status pesanan untuk halaman pelanggan. Tanpa nomor WA. Galat: E:invalid_order
create or replace function public.online_order_status(p_tenant uuid, p_token text) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; v_fig jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then raise exception 'E:invalid_order'; end if;
  select * into o from public.orders where tenant_id = p_tenant and public_token = p_token and source = 'online';
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_order'; end if;
  if o.status = 'pending' then
    perform public._expire_online(p_tenant, o.id);
    select * into o from public.orders where id = o.id;
  end if;
  v_fig := case when o.bill_id is not null then public._bill_figures(o.bill_id) else o.quote end;
  return jsonb_build_object(
    'order_no', o.order_no, 'status', o.status, 'name', o.customer_name, 'pickup_by', o.pickup_by, 'pay_plan', o.pay_plan,
    'pay_claimed', o.pay_claimed_at is not null, 'paid', o.payment_status = 'paid', 'reject_reason', case when o.status = 'rejected' then o.reject_reason end,
    'created_at', o.created_at, 'note', o.note,
    'figures', jsonb_build_object('subtotal', v_fig->'subtotal', 'discount', coalesce(v_fig->'discount', '0'::jsonb), 'service', v_fig->'service', 'tax', v_fig->'tax', 'total', v_fig->'total'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'qty', i.qty, 'line_total', i.line_total) order by i.name_snapshot) from public.order_items i where i.order_id = o.id), '[]'::jsonb));
end $$;

-- "Saya sudah bayar" (jalur B). Hanya menandai; staf yang memverifikasi. Idempotent. Galat: E:invalid_order
create or replace function public.claim_online_payment(p_tenant uuid, p_token text) returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then raise exception 'E:invalid_order'; end if;
  select * into o from public.orders where tenant_id = p_tenant and public_token = p_token and source = 'online' for update;
  if not found or o.pay_plan <> 'prepay_qris' or o.status <> 'pending' then raise exception 'E:invalid_order'; end if;
  update public.orders set pay_claimed_at = coalesce(pay_claimed_at, now()) where id = o.id;
end $$;

-- =====================================================================
-- 5. STAF (Cashier / Manager / Owner)
-- =====================================================================
-- Muat ulang daftar: kedaluwarsakan pesanan yang lewat 15 menit. Boleh dipanggil semua anggota (hanya menutup yang memang sudah lewat waktu).
create or replace function public.sweep_online_orders(p_tenant uuid) returns int language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_tenant) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  return public._expire_online(p_tenant);
end $$;

-- Terima pesanan bayar-di-tempat: buat tagihan, masuk dapur.
create or replace function public.accept_online_order(p_order uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if not found or o.source <> 'online' or not public.has_role(o.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  perform public._expire_online(o.tenant_id, o.id); select * into o from public.orders where id = p_order;
  if o.status = 'expired' then raise exception 'Pesanan sudah kedaluwarsa (tidak dikonfirmasi dalam 15 menit)' using errcode = 'check_violation'; end if;
  if o.status <> 'pending' then raise exception 'Pesanan ini sudah diproses' using errcode = 'check_violation'; end if;
  if o.pay_plan = 'prepay_qris' then raise exception 'Pesanan ini dibayar di muka: gunakan "Pembayaran diterima"' using errcode = 'check_violation'; end if;
  return public._open_online_bill(o);
end $$;

-- Pembayaran di muka (QRIS) sudah dicek staf di aplikasi merchant: buat tagihan, lunasi (QRIS) dan masuk dapur — atomik.
create or replace function public.accept_online_prepaid(p_order uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare o public.orders; v_bill uuid; v_total int; v_quote int;
begin
  select * into o from public.orders where id = p_order for update;
  if not found or o.source <> 'online' or not public.has_role(o.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if o.pay_plan <> 'prepay_qris' then raise exception 'Pesanan ini dibayar di tempat: gunakan "Terima"' using errcode = 'check_violation'; end if;
  perform public._expire_online(o.tenant_id, o.id); select * into o from public.orders where id = p_order;
  if o.status = 'expired' then raise exception 'Pesanan sudah kedaluwarsa (tidak dikonfirmasi dalam 15 menit)' using errcode = 'check_violation'; end if;
  if o.status <> 'pending' then raise exception 'Pesanan ini sudah diproses' using errcode = 'check_violation'; end if;
  v_quote := (o.quote->>'total')::int;
  v_total := (public._online_figures(o.tenant_id, o.total_idr)->>'total')::int;
  if v_quote is distinct from v_total then
    raise exception 'Pajak/biaya layanan berubah sejak pesanan dibuat (pelanggan diminta Rp %, sekarang Rp %). Tolak pesanan ini lalu kembalikan dana pelanggan.', v_quote, v_total using errcode = 'check_violation';
  end if;
  v_bill := public._open_online_bill(o);
  perform public.pay_bill(v_bill, jsonb_build_array(jsonb_build_object('method', 'qris', 'amount', v_total)));
  return v_bill;
end $$;

create or replace function public.reject_online_order(p_order uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if not found or o.source <> 'online' or not public.has_role(o.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if o.status <> 'pending' then raise exception 'Hanya pesanan yang menunggu konfirmasi yang bisa ditolak' using errcode = 'check_violation'; end if;
  update public.orders set status = 'rejected', reject_reason = left(nullif(btrim(p_reason), ''), 200) where id = o.id;
end $$;

-- Pengaturan pesanan online (Owner). p_qris_key = kunci gambar QRIS hasil unggah (atau null untuk menghapus).
create or replace function public.set_online_settings(p_tenant uuid, p_enabled boolean, p_prepay boolean, p_qris_key text, p_note text) returns void language plpgsql security definer set search_path = public as $$
declare v_key text := nullif(btrim(p_qris_key), '');
begin
  if not public.has_role(p_tenant, array['owner']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if v_key is not null and v_key !~ '^restaurant/tenants/[a-z0-9-]+/qris/[a-z0-9-]+\.webp$' then raise exception 'Gambar QRIS tidak valid' using errcode = 'check_violation'; end if;
  if coalesce(p_prepay, false) and v_key is null then raise exception 'Unggah gambar QRIS dulu untuk mengaktifkan bayar di muka' using errcode = 'check_violation'; end if;
  if char_length(coalesce(p_note, '')) > 300 then raise exception 'Petunjuk pengambilan maksimal 300 karakter' using errcode = 'check_violation'; end if;
  update public.tenants set online_enabled = coalesce(p_enabled, false), online_prepay_enabled = coalesce(p_prepay, false) and v_key is not null, qris_image_key = v_key, pickup_note = nullif(btrim(p_note), '') where id = p_tenant;
end $$;

-- =====================================================================
-- 6. FUNGSI LAMA YANG DIPERLUAS
-- =====================================================================
-- set_order_status: pesanan online yang belum dikonfirmasi hanya lewat Terima/Tolak; membatalkan pesanan online yang sudah diterima ikut menutup (void) tagihannya.
create or replace function public.set_order_status(p_order uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_old text; v_role text; v_ok boolean; v_bill_status text; v_bill uuid; v_source text;
begin
  if p_status not in ('new', 'preparing', 'ready', 'done', 'cancelled') then raise exception 'Status tidak valid' using errcode = 'check_violation'; end if;
  select o.tenant_id, o.status, b.status, o.bill_id, o.source into v_tenant, v_old, v_bill_status, v_bill, v_source from public.orders o left join public.bills b on b.id = o.bill_id where o.id = p_order;
  v_role := public.tenant_role(v_tenant);
  v_ok := case when v_role in ('super_admin', 'owner', 'manager', 'cashier') then true
               when v_role = 'kitchen' then p_status in ('preparing', 'ready') and v_old in ('new', 'preparing')
               when v_role = 'service' then p_status = 'done' and v_old = 'ready'
               else false end;
  if v_tenant is null or not v_ok then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if v_old in ('pending', 'rejected', 'expired') then raise exception 'Pesanan online ini belum dikonfirmasi atau sudah ditutup: gunakan Terima / Tolak' using errcode = 'check_violation'; end if;
  if (p_status = 'cancelled' or v_old = 'cancelled') and v_bill_status is not null and v_bill_status <> 'open' then
    raise exception 'Tagihan pesanan ini sudah ditutup. Batalkan pembayarannya dulu (Manager/Owner).' using errcode = 'check_violation'; end if;
  update public.orders set status = p_status where id = p_order;
  if p_status = 'cancelled' and v_source = 'online' and v_bill is not null and v_bill_status = 'open'
     and not exists (select 1 from public.orders where bill_id = v_bill and status <> 'cancelled') then
    update public.bills set status = 'void', closed_at = now(), closed_by = auth.uid(), close_reason = 'Pesanan online dibatalkan' where id = v_bill;
  end if;
end $$;

-- Data publik restoran: tambahkan pengaturan pesanan online (menyambung ke versi 11: base + template_id + menu_display).
create or replace function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select public.tenant_public_json_base(p_id) || (select jsonb_build_object('template_id', t.template_id, 'menu_display', t.menu_display,
           'online_enabled', t.online_enabled, 'online_prepay', t.online_enabled and t.online_prepay_enabled and t.qris_image_key is not null,
           'qris_image_key', case when t.online_enabled and t.online_prepay_enabled then t.qris_image_key end, 'pickup_note', t.pickup_note)
         from public.tenants t where t.id = p_id)
$$;

-- list_bills (versi 10) + sumber & pengambil pesanan agar kasir tahu saat pelanggan datang.
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
          'total_idr', o.total_idr, 'note', o.note, 'created_at', o.created_at, 'source', o.source, 'pickup_by', o.pickup_by, 'pay_plan', o.pay_plan,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'qty', i.qty, 'line_total', i.line_total) order by i.name_snapshot) from public.order_items i where i.order_id = o.id), '[]'::jsonb)
        ) order by o.created_at) from public.orders o where o.bill_id = b.id), '[]'::jsonb),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.method, 'amount_idr', p.amount_idr, 'tendered_idr', p.tendered_idr) order by p.created_at) from public.payments p where p.bill_id = b.id and p.voided_at is null), '[]'::jsonb),
      'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'summary', e.summary, 'at', e.created_at, 'undone', e.undone_at is not null,
          'by', (select split_part(u.email, '@', 1) from auth.users u where u.id = e.actor)) order by e.created_at desc) from public.bill_events e where e.bill_id = b.id), '[]'::jsonb),
      'undo', case when b.status = 'open' then (select jsonb_build_object('summary', e.summary) from public.bill_events e where e.bill_id = b.id and e.undone_at is null and e.locked_at is null order by e.created_at desc, e.id desc limit 1) end
    ) as x
    from public.bills b
    where b.tenant_id = p_tenant
      and ((p_scope = 'open' and b.status = 'open') or (p_scope = 'closed' and b.status in ('paid', 'void') and coalesce(b.closed_at, b.paid_at) >= v_from))
    order by coalesce(b.closed_at, b.opened_at) desc limit 200
  ) s;
  return v_out;
end $$;

-- =====================================================================
-- 7. HAK EKSEKUSI
-- =====================================================================
revoke execute on function public.place_online_order(uuid, jsonb, text, text, text, text, text, text, text), public.online_order_status(uuid, text), public.claim_online_payment(uuid, text),
  public.sweep_online_orders(uuid), public.accept_online_order(uuid), public.accept_online_prepaid(uuid), public.reject_online_order(uuid, text), public.set_online_settings(uuid, boolean, boolean, text, text),
  public.order_visible(uuid, text) from public, anon;
grant execute on function public.place_online_order(uuid, jsonb, text, text, text, text, text, text, text), public.online_order_status(uuid, text), public.claim_online_payment(uuid, text) to anon, authenticated;
grant execute on function public.sweep_online_orders(uuid), public.accept_online_order(uuid), public.accept_online_prepaid(uuid), public.reject_online_order(uuid, text), public.set_online_settings(uuid, boolean, boolean, text, text),
  public.order_visible(uuid, text) to authenticated;
