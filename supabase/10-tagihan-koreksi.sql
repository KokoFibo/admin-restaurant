-- 10-tagihan-koreksi.sql — RIWAYAT TINDAKAN + UNDO (urungkan) untuk gabung meja, gabung tagihan, pisah pesanan, dan diskon.
-- Jalankan SETELAH 09-tagihan.sql. Aman diulang.
--
-- Aturan
--   • Setiap tindakan di tagihan terbuka menyimpan kondisi sebelumnya (bill_events.undo). undo_last(tagihan) mengurungkan tindakan TERAKHIR
--     yang belum diurungkan; untuk mengurungkan yang lebih lama, urungkan yang di atasnya dulu.
--   • Pesanan yang masuk SETELAH gabung dikembalikan ke tagihan meja asalnya saat di-undo.
--   • Saat tagihan dibayar, riwayatnya dikunci (tidak bisa di-undo lagi, juga setelah "Batalkan pembayaran").

create table if not exists public.bill_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  bill_id uuid not null,                         -- tagihan tempat riwayat ini tampil (tagihan hasil)
  kind text not null check (kind in ('merge_tables', 'merge_bills', 'split', 'discount')),
  summary text not null,
  undo jsonb not null,                           -- data untuk mengembalikan kondisi sebelumnya
  actor uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  undone_at timestamptz, undone_by uuid references auth.users(id) on delete set null,
  locked_at timestamptz                          -- diisi saat tagihan dibayar
);
create index if not exists bill_events_bill on public.bill_events(bill_id, created_at desc);
alter table public.bill_events enable row level security;
drop policy if exists "baca riwayat tagihan" on public.bill_events;
create policy "baca riwayat tagihan" on public.bill_events for select to authenticated using (public.has_role(tenant_id, array['owner', 'manager', 'cashier']));

-- Kunci riwayat saat tagihan menjadi lunas.
create or replace function public.lock_bill_events() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.bill_events set locked_at = now() where bill_id = new.id and undone_at is null and locked_at is null;
  return new;
end $$;
drop trigger if exists bills_lock_events on public.bills;
create trigger bills_lock_events after update of status on public.bills for each row when (new.status = 'paid' and old.status is distinct from 'paid') execute function public.lock_bill_events();

create or replace function public._log_event(p_tenant uuid, p_bill uuid, p_kind text, p_summary text, p_undo jsonb) returns void language sql security definer set search_path = public as $$
  insert into public.bill_events (tenant_id, bill_id, kind, summary, undo, actor) values (p_tenant, p_bill, p_kind, p_summary, p_undo, auth.uid());
$$;

-- Lebur tagihan p_sources ke p_target. Mengembalikan "foto" kondisi sebelumnya (untuk undo).
create or replace function public._merge_into(p_target uuid, p_sources uuid[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_snap jsonb := '[]'::jsonb; v_disc int; v_req timestamptz; v_lbl text; v_src uuid; x public.bills;
begin
  for x in select * from public.bills where id = p_target or id = any (p_sources) order by (id = p_target) desc, id loop
    v_snap := v_snap || jsonb_build_array(jsonb_build_object('id', x.id, 'is_target', x.id = p_target, 'discount_idr', x.discount_idr,
      'requested_at', x.bill_requested_at, 'requested_label', x.bill_requested_label,
      'orders', coalesce((select jsonb_agg(o.id) from public.orders o where o.bill_id = x.id), '[]'::jsonb),
      'bill_tables', coalesce((select jsonb_agg(bt.id) from public.bill_tables bt where bt.bill_id = x.id), '[]'::jsonb)));
  end loop;
  select coalesce(sum(discount_idr), 0)::int, min(bill_requested_at) into v_disc, v_req from public.bills where id = p_target or id = any (p_sources);
  select bill_requested_label into v_lbl from public.bills where (id = p_target or id = any (p_sources)) and bill_requested_at is not null order by bill_requested_at limit 1;
  foreach v_src in array p_sources loop
    update public.bill_tables set bill_id = p_target where bill_id = v_src;
    update public.orders set bill_id = p_target where bill_id = v_src;
    update public.bills set status = 'merged', merged_into = p_target, closed_at = now(), closed_by = auth.uid() where id = v_src;
  end loop;
  update public.bills set discount_idr = v_disc, bill_requested_at = v_req, bill_requested_label = v_lbl where id = p_target;
  return v_snap;
end $$;
revoke all on function public._log_event(uuid, uuid, text, text, jsonb), public._merge_into(uuid, uuid[]) from public, anon, authenticated;

-- Gabungkan 2+ meja (dengan riwayat). Meja kosong ikut bergabung; tagihan yang sudah ada dilebur ke yang tertua.
create or replace function public.merge_tables(p_tenant uuid, p_tables uuid[]) returns uuid language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_target uuid; v_snap jsonb := '[]'::jsonb; v_att uuid[]; v_created boolean := false; v_label text;
begin
  if not public.has_role(p_tenant, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  select array_agg(distinct x) into p_tables from unnest(p_tables) x;
  if p_tables is null or cardinality(p_tables) < 2 then raise exception 'Pilih minimal 2 meja' using errcode = 'check_violation'; end if;
  perform 1 from public.restaurant_tables where tenant_id = p_tenant and id = any (p_tables) order by id for update;
  if (select count(*) from public.restaurant_tables where tenant_id = p_tenant and id = any (p_tables)) <> cardinality(p_tables) then raise exception 'Meja tidak ditemukan' using errcode = 'check_violation'; end if;
  select string_agg(label, ' + ' order by label) into v_label from public.restaurant_tables where id = any (p_tables);

  select array_agg(id order by opened_at, id) into v_ids from (
    select distinct b.id, b.opened_at from public.bills b join public.bill_tables bt on bt.bill_id = b.id
     where b.tenant_id = p_tenant and b.status = 'open' and bt.is_open and bt.table_id = any (p_tables)) s;
  if v_ids is null then
    v_target := public._open_bill(p_tenant, p_tables); v_created := true;
    select array_agg(id) into v_att from public.bill_tables where bill_id = v_target;
  else
    perform 1 from public.bills where id = any (v_ids) order by id for update;
    v_target := v_ids[1];
    v_snap := public._merge_into(v_target, v_ids[2:]);
    with ins as (
      insert into public.bill_tables (bill_id, tenant_id, table_id, table_label)
        select v_target, p_tenant, t.id, t.label from public.restaurant_tables t
         where t.tenant_id = p_tenant and t.id = any (p_tables) and not exists (select 1 from public.bill_tables bt where bt.table_id = t.id and bt.is_open)
      returning id) select array_agg(id) into v_att from ins;
    if cardinality(v_ids) = 1 and v_att is null then raise exception 'Meja-meja ini sudah dalam satu tagihan' using errcode = 'check_violation'; end if;
  end if;
  perform public._log_event(p_tenant, v_target, 'merge_tables', 'Gabung meja ' || v_label, jsonb_build_object('created_target', v_created, 'attached', coalesce(to_jsonb(v_att), '[]'::jsonb), 'sources', v_snap));
  return v_target;
end $$;

-- Gabungkan tagihan terbuka lain (termasuk tagihan hasil pisahan) ke p_target.
create or replace function public.merge_bills(p_target uuid, p_sources uuid[]) returns uuid language plpgsql security definer set search_path = public as $$
declare t public.bills; v_nos text; v_snap jsonb;
begin
  select array_agg(distinct x) into p_sources from unnest(p_sources) x where x <> p_target;
  if p_sources is null then raise exception 'Pilih tagihan lain untuk digabung' using errcode = 'check_violation'; end if;
  perform 1 from public.bills where id = p_target or id = any (p_sources) order by id for update;
  select * into t from public.bills where id = p_target;
  if not found or not public.has_role(t.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if t.status <> 'open' or (select count(*) from public.bills where id = any (p_sources) and tenant_id = t.tenant_id and status = 'open') <> cardinality(p_sources) then
    raise exception 'Semua tagihan harus terbuka dan dari restoran yang sama' using errcode = 'check_violation'; end if;
  select string_agg('#' || lpad(bill_no::text, 4, '0'), ' + ' order by bill_no) into v_nos from public.bills where id = any (p_sources);
  v_snap := public._merge_into(p_target, p_sources);
  perform public._log_event(t.tenant_id, p_target, 'merge_bills', 'Gabung tagihan ' || v_nos || ' → #' || lpad(t.bill_no::text, 4, '0'), jsonb_build_object('created_target', false, 'attached', '[]'::jsonb, 'sources', v_snap));
  return p_target;
end $$;

-- Pisahkan pesanan (dengan riwayat).
create or replace function public.split_orders(p_orders uuid[]) returns uuid language plpgsql security definer set search_path = public as $$
declare v_bills uuid[]; v_b public.bills; v_new uuid; v_n int; v_no int;
begin
  select array_agg(distinct bill_id) into v_bills from public.orders where id = any (p_orders);
  if v_bills is null or cardinality(v_bills) <> 1 or (select count(*) from public.orders where id = any (p_orders)) <> cardinality(p_orders) then
    raise exception 'Pilih pesanan dari satu tagihan yang sama' using errcode = 'check_violation'; end if;
  select * into v_b from public.bills where id = v_bills[1] for update;
  if not public.has_role(v_b.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if v_b.status <> 'open' then raise exception 'Tagihan sudah ditutup' using errcode = 'check_violation'; end if;
  select count(*) into v_n from public.orders where bill_id = v_b.id and status <> 'cancelled' and id <> all (p_orders);
  if v_n = 0 then raise exception 'Sisakan minimal satu pesanan di tagihan asal' using errcode = 'check_violation'; end if;
  v_no := public._next_bill_no(v_b.tenant_id);
  insert into public.bills (tenant_id, bill_no, label) values (v_b.tenant_id, v_no, 'Pisahan dari #' || lpad(v_b.bill_no::text, 4, '0')) returning id into v_new;
  update public.orders set bill_id = v_new where id = any (p_orders);
  perform public._log_event(v_b.tenant_id, v_b.id, 'split', 'Pisahkan ' || cardinality(p_orders) || ' pesanan ke #' || lpad(v_no::text, 4, '0'), jsonb_build_object('new_bill', v_new, 'orders', to_jsonb(p_orders)));
  return v_new;
end $$;

-- Diskon (dengan riwayat bila berubah).
create or replace function public.set_bill_discount(p_bill uuid, p_amount int) returns void language plpgsql security definer set search_path = public as $$
declare b public.bills; v_sub int;
begin
  select * into b from public.bills where id = p_bill for update;
  if not found or not public.has_role(b.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if b.status <> 'open' then raise exception 'Tagihan sudah ditutup' using errcode = 'check_violation'; end if;
  select coalesce(sum(total_idr), 0)::int into v_sub from public.orders where bill_id = b.id and status <> 'cancelled';
  if p_amount is null or p_amount < 0 or p_amount > v_sub then raise exception 'Diskon harus antara 0 dan subtotal (Rp %)', v_sub using errcode = 'check_violation'; end if;
  if p_amount = b.discount_idr then return; end if;
  update public.bills set discount_idr = p_amount where id = b.id;
  perform public._log_event(b.tenant_id, b.id, 'discount', 'Diskon Rp ' || b.discount_idr || ' → Rp ' || p_amount, jsonb_build_object('prev', b.discount_idr));
end $$;

-- URUNGKAN tindakan terakhir pada tagihan terbuka (hanya sebelum dibayar).
create or replace function public.undo_last(p_bill uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bills; e public.bill_events; u jsonb; v_x jsonb; v_all uuid[]; v_att uuid[]; sb public.bills; v_new uuid; rec record; v_owner uuid;
begin
  select * into b from public.bills where id = p_bill for update;
  if not found or not public.has_role(b.tenant_id, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if b.status <> 'open' then raise exception 'Hanya tagihan terbuka yang bisa diurungkan' using errcode = 'check_violation'; end if;
  select * into e from public.bill_events where bill_id = p_bill and undone_at is null and locked_at is null order by created_at desc, id desc limit 1;
  if not found then raise exception 'Tidak ada tindakan yang bisa diurungkan' using errcode = 'check_violation'; end if;
  u := e.undo;

  if e.kind = 'discount' then
    update public.bills set discount_idr = (u->>'prev')::int where id = p_bill;

  elsif e.kind = 'split' then
    v_new := (u->>'new_bill')::uuid;
    select * into sb from public.bills where id = v_new for update;
    if sb.status <> 'open' then raise exception 'Tagihan pisahan sudah ditutup/dibayar; tidak bisa diurungkan' using errcode = 'check_violation'; end if;
    if exists (select 1 from public.bill_events where bill_id = v_new and undone_at is null and locked_at is null) then
      raise exception 'Urungkan dulu tindakan pada tagihan pisahan #%', lpad(sb.bill_no::text, 4, '0') using errcode = 'check_violation'; end if;
    update public.orders set bill_id = p_bill where bill_id = v_new;
    update public.bills set status = 'void', closed_at = now(), closed_by = auth.uid(), close_reason = 'undo pisah' where id = v_new;

  else   -- merge_tables | merge_bills
    select array_agg(v::uuid) into v_all from jsonb_array_elements(u->'sources') x, jsonb_array_elements_text(x->'orders') v;
    for v_x in select * from jsonb_array_elements(u->'sources') loop
      if (v_x->>'is_target')::boolean then
        update public.bills set discount_idr = (v_x->>'discount_idr')::int, bill_requested_at = nullif(v_x->>'requested_at', '')::timestamptz, bill_requested_label = v_x->>'requested_label' where id = p_bill;
      else
        select * into sb from public.bills where id = (v_x->>'id')::uuid for update;
        if sb.status <> 'merged' or sb.merged_into is distinct from p_bill then raise exception 'Kondisi tagihan sudah berubah; tidak bisa diurungkan' using errcode = 'check_violation'; end if;
        update public.bills set status = 'open', merged_into = null, closed_at = null, closed_by = null, discount_idr = (v_x->>'discount_idr')::int,
               bill_requested_at = nullif(v_x->>'requested_at', '')::timestamptz, bill_requested_label = v_x->>'requested_label' where id = sb.id;
        update public.bill_tables set bill_id = sb.id where bill_id = p_bill and id in (select jsonb_array_elements_text(v_x->'bill_tables')::uuid);
        update public.orders set bill_id = sb.id where bill_id = p_bill and id in (select jsonb_array_elements_text(v_x->'orders')::uuid);
      end if;
    end loop;
    -- pesanan yang masuk SETELAH gabung → ke tagihan pemilik mejanya sekarang
    for rec in select id, table_id from public.orders where bill_id = p_bill and table_id is not null and id <> all (coalesce(v_all, '{}')) loop
      select bt.bill_id into v_owner from public.bill_tables bt where bt.table_id = rec.table_id and bt.is_open limit 1;
      if v_owner is not null and v_owner <> p_bill then update public.orders set bill_id = v_owner where id = rec.id; end if;
    end loop;
    -- meja kosong yang tadi ikut bergabung dilepas lagi (kecuali sudah ada pesanan dari meja itu)
    select array_agg(x::uuid) into v_att from jsonb_array_elements_text(u->'attached') x;
    delete from public.bill_tables bt where bt.id = any (coalesce(v_att, '{}')) and bt.bill_id = p_bill
       and not exists (select 1 from public.orders o where o.bill_id = p_bill and o.table_id = bt.table_id);
    if (u->>'created_target')::boolean and not exists (select 1 from public.orders where bill_id = p_bill) then
      update public.bill_tables set is_open = false where bill_id = p_bill;
      update public.bills set status = 'void', closed_at = now(), closed_by = auth.uid(), close_reason = 'undo gabung' where id = p_bill;
    end if;
  end if;

  update public.bill_events set undone_at = now(), undone_by = auth.uid() where id = e.id;
  return jsonb_build_object('kind', e.kind, 'summary', e.summary);
end $$;

-- list_bills + riwayat & tombol urungkan
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

revoke execute on function public.merge_bills(uuid, uuid[]), public.undo_last(uuid) from public, anon;
grant execute on function public.merge_bills(uuid, uuid[]), public.undo_last(uuid) to authenticated;
