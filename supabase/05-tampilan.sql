-- 05-tampilan.sql — tahap 1 tampilan website: warna, banner, tutup sementara, hidangan unggulan (jalankan SETELAH 04; aman diulang).
--  • Skema warna & warna kustom: Owner (pilihan terbatas + cek kontras) | Super Admin (bebas, termasuk latar gelap)
--  • Banner info/promo/libur: Owner & Manager & Super Admin. Banner libur bisa menutup pemesanan QR.
--  • Tutup sementara: Owner, Manager, Super Admin. Hidangan unggulan: Owner/Manager/Super Admin lewat hak edit menu.
--  • Zona waktu restoran: hanya Super Admin.

alter table public.tenants
  add column if not exists theme text not null default 'giok' check (theme in ('giok', 'teh', 'samudra', 'bata', 'anggur', 'zaitun', 'arang', 'custom')),
  add column if not exists theme_custom jsonb,
  add column if not exists theme_dark boolean not null default false,
  add column if not exists timezone text not null default 'Asia/Jakarta' check (timezone in ('Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura')),
  add column if not exists orders_paused boolean not null default false;
alter table public.menu_items add column if not exists is_featured boolean not null default false;

-- Kolom lama primary_color tidak dipakai lagi; hak ubah Owner dicabut. Pengaturan tema lewat set_tenant_theme.
revoke update on public.tenants from anon, authenticated;
grant update (phone, whatsapp, email, maps_url, address, opening_hours) on public.tenants to authenticated;

-- ---------- warna ----------
create or replace function public.hex_luminance(h text) returns float8 language plpgsql immutable as $$
declare r float8; g float8; b float8;
begin
  r := ('x' || substr(h, 2, 2))::bit(8)::int / 255.0; g := ('x' || substr(h, 4, 2))::bit(8)::int / 255.0; b := ('x' || substr(h, 6, 2))::bit(8)::int / 255.0;
  r := case when r <= 0.03928 then r / 12.92 else power((r + 0.055) / 1.055, 2.4) end;
  g := case when g <= 0.03928 then g / 12.92 else power((g + 0.055) / 1.055, 2.4) end;
  b := case when b <= 0.03928 then b / 12.92 else power((b + 0.055) / 1.055, 2.4) end;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
end $$;
create or replace function public.contrast_ratio(a text, b text) returns float8 language sql immutable as $$
  select (greatest(public.hex_luminance(a), public.hex_luminance(b)) + 0.05) / (least(public.hex_luminance(a), public.hex_luminance(b)) + 0.05)
$$;

-- p_custom = {"primary": "#RRGGBB", "accent": "#RRGGBB", "bg": "#RRGGBB"}; hanya dipakai bila p_theme = 'custom'.
-- Owner: warna dasar dari daftar pilihan; Super Admin: bebas + latar gelap. Keduanya wajib lolos kontras (WCAG 4,5:1).
create or replace function public.set_tenant_theme(p_tenant uuid, p_theme text, p_custom jsonb default null, p_dark boolean default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := public.tenant_role(p_tenant); v_super boolean := public.is_platform_admin(); v_cur boolean; v_dark boolean; pr text; ac text; bg text;
  v_bgs text[] := array['#FFFFFF', '#FBF8F2', '#FAF5EA', '#F5F5F3', '#F3F8F4', '#F2F7FA'];
begin
  if v_role is null or v_role not in ('super_admin', 'owner') then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_theme not in ('giok', 'teh', 'samudra', 'bata', 'anggur', 'zaitun', 'arang', 'custom') then raise exception 'Skema warna tidak dikenal' using errcode = 'check_violation'; end if;
  select theme_dark into v_cur from public.tenants where id = p_tenant;
  if p_dark is not null and p_dark is distinct from v_cur and not v_super then raise exception 'Latar gelap hanya bisa diatur Super Admin' using errcode = '42501'; end if;
  v_dark := coalesce(p_dark, v_cur);
  if v_dark and p_theme <> 'custom' then raise exception 'Latar gelap memakai warna kustom' using errcode = 'check_violation'; end if;
  if p_theme = 'custom' then
    pr := upper(p_custom->>'primary'); ac := upper(p_custom->>'accent'); bg := upper(p_custom->>'bg');
    if pr !~ '^#[0-9A-F]{6}$' or ac !~ '^#[0-9A-F]{6}$' or bg !~ '^#[0-9A-F]{6}$' then raise exception 'Format warna harus #RRGGBB' using errcode = 'check_violation'; end if;
    if not v_super and not (bg = any (v_bgs)) then raise exception 'Warna dasar tidak ada dalam daftar pilihan' using errcode = 'check_violation'; end if;
    if not v_dark and public.hex_luminance(bg) < 0.5 then raise exception 'Warna dasar gelap hanya dengan mode latar gelap (Super Admin)' using errcode = 'check_violation'; end if;
    if v_dark and public.hex_luminance(bg) > 0.2 then raise exception 'Mode latar gelap membutuhkan warna dasar yang gelap' using errcode = 'check_violation'; end if;
    if public.contrast_ratio(pr, bg) < 4.5 then raise exception 'Warna utama kurang kontras terhadap warna dasar (minimal 4,5:1)' using errcode = 'check_violation'; end if;
    if public.contrast_ratio('#FFFFFF', ac) < 4.5 then raise exception 'Warna aksen terlalu terang untuk teks putih pada tombol (minimal 4,5:1)' using errcode = 'check_violation'; end if;
  end if;
  update public.tenants set theme = p_theme, theme_dark = v_dark,
    theme_custom = case when p_theme = 'custom' then jsonb_build_object('primary', pr, 'accent', ac, 'bg', bg) else theme_custom end where id = p_tenant;
end $$;

create or replace function public.set_tenant_timezone(p_tenant uuid, p_tz text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_tz not in ('Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura') then raise exception 'Zona waktu tidak dikenal' using errcode = 'check_violation'; end if;
  update public.tenants set timezone = p_tz where id = p_tenant;
end $$;

-- ---------- tutup sementara ----------
create or replace function public.tenant_today(p_tenant uuid) returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone coalesce((select timezone from public.tenants where id = p_tenant), 'Asia/Jakarta'))::date
$$;
create or replace function public.set_orders_paused(p_tenant uuid, p_paused boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner', 'manager']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  update public.tenants set orders_paused = coalesce(p_paused, false) where id = p_tenant;
end $$;

-- ---------- banner ----------
create table if not exists public.site_banners (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  kind text not null default 'info' check (kind in ('info', 'promo', 'holiday')),
  starts_on date not null, ends_on date not null,
  scope text not null default 'all' check (scope in ('all', 'home', 'order')),
  link_url text check (link_url is null or (char_length(link_url) <= 300 and link_url ~ '^(https://|/)')),
  blocks_orders boolean not null default false,
  is_active boolean not null default true,
  sort int4 not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (ends_on >= starts_on), check (not blocks_orders or kind = 'holiday')
);
create index if not exists site_banners_tenant on public.site_banners(tenant_id, starts_on);
create table if not exists public.site_banner_translations (
  banner_id uuid not null references public.site_banners(id) on delete cascade,
  lang text not null references public.languages(code),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 140),
  link_label text check (link_label is null or char_length(link_label) <= 30),
  is_locked boolean not null default false,
  source text not null default 'manual' check (source in ('manual', 'ai')),
  primary key (banner_id, lang)
);
alter table public.site_banners enable row level security;
alter table public.site_banner_translations enable row level security;
create or replace function public.can_edit_banner(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(p_tenant, array['owner', 'manager'])
$$;
drop policy if exists "pengelola kelola banner" on public.site_banners;
create policy "pengelola kelola banner" on public.site_banners for all to authenticated using (public.can_edit_banner(tenant_id)) with check (public.can_edit_banner(tenant_id));
drop policy if exists "pengelola kelola terjemahan banner" on public.site_banner_translations;
create policy "pengelola kelola terjemahan banner" on public.site_banner_translations for all to authenticated using (public.can_edit_banner(tenant_id)) with check (public.can_edit_banner(tenant_id));
grant select, insert, update, delete on public.site_banners, public.site_banner_translations to authenticated;
drop trigger if exists site_banners_touch on public.site_banners;
create trigger site_banners_touch before update on public.site_banners for each row execute function public.touch_updated_at();

-- p = { id?, tenant_id, kind, starts_on, ends_on, scope, link_url, blocks_orders, is_active, tr: [{lang, message, link_label, is_locked, source}] }
create or replace function public.save_banner(p jsonb) returns uuid language plpgsql set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_t uuid := (p->>'tenant_id')::uuid; v_end date := (p->>'ends_on')::date; v_active boolean := coalesce((p->>'is_active')::boolean, true); x jsonb; v_n int;
begin
  if not public.can_edit_banner(v_t) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(p->'tr', '[]'::jsonb)) = 0 then raise exception 'Isi teks banner minimal satu bahasa' using errcode = 'check_violation'; end if;
  if nullif(btrim(p->>'link_url'), '') is not null and (p->>'link_url' !~ '^(https://|/)' or char_length(p->>'link_url') > 300) then raise exception 'Tautan harus diawali https:// atau / (maks 300 karakter)' using errcode = 'check_violation'; end if;
  if v_end < (p->>'starts_on')::date then raise exception 'Tanggal selesai tidak boleh sebelum tanggal mulai' using errcode = 'check_violation'; end if;
  if coalesce((p->>'blocks_orders')::boolean, false) and p->>'kind' <> 'holiday' then raise exception 'Hanya banner Libur yang bisa menutup pemesanan' using errcode = 'check_violation'; end if;
  if v_active and v_end >= public.tenant_today(v_t) then
    select count(*) into v_n from public.site_banners where tenant_id = v_t and is_active and ends_on >= public.tenant_today(v_t) and id is distinct from v_id;
    if v_n >= 3 then raise exception 'Maksimal 3 banner aktif sekaligus' using errcode = 'check_violation'; end if;
  end if;
  if v_id is null then
    select count(*) into v_n from public.site_banners where tenant_id = v_t; if v_n >= 20 then raise exception 'Terlalu banyak banner; hapus yang sudah berakhir' using errcode = 'check_violation'; end if;
    insert into public.site_banners (tenant_id, kind, starts_on, ends_on, scope, link_url, blocks_orders, is_active, created_by)
      values (v_t, p->>'kind', (p->>'starts_on')::date, v_end, coalesce(p->>'scope', 'all'), nullif(btrim(p->>'link_url'), ''), coalesce((p->>'blocks_orders')::boolean, false), v_active, auth.uid()) returning id into v_id;
  else
    update public.site_banners set kind = p->>'kind', starts_on = (p->>'starts_on')::date, ends_on = v_end, scope = coalesce(p->>'scope', 'all'), link_url = nullif(btrim(p->>'link_url'), ''),
      blocks_orders = coalesce((p->>'blocks_orders')::boolean, false), is_active = v_active where id = v_id and tenant_id = v_t;
    if not found then raise exception 'Banner tidak ditemukan' using errcode = 'no_data_found'; end if;
    delete from public.site_banner_translations where banner_id = v_id and lang not in (select e->>'lang' from jsonb_array_elements(p->'tr') e);
  end if;
  for x in select * from jsonb_array_elements(p->'tr') loop
    insert into public.site_banner_translations (banner_id, lang, tenant_id, message, link_label, is_locked, source)
      values (v_id, x->>'lang', v_t, btrim(x->>'message'), nullif(btrim(x->>'link_label'), ''), coalesce((x->>'is_locked')::boolean, false), coalesce(x->>'source', 'manual'))
      on conflict (banner_id, lang) do update set message = excluded.message, link_label = excluded.link_label, is_locked = excluded.is_locked, source = excluded.source;
  end loop;
  return v_id;
end $$;

-- Banner yang sedang tayang (menurut zona waktu restoran). rev berubah bila isi berubah → frontend boleh menampilkan lagi banner yang sudah ditutup pengunjung.
create or replace function public.live_banners_json(p_tenant uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'scope', b.scope, 'link_url', b.link_url, 'blocks_orders', b.blocks_orders, 'rev', extract(epoch from b.updated_at)::bigint,
      'texts', (select coalesce(jsonb_object_agg(x.lang, jsonb_build_object('message', x.message, 'link_label', x.link_label)), '{}'::jsonb) from public.site_banner_translations x where x.banner_id = b.id))
    order by b.sort, b.starts_on, b.created_at), '[]'::jsonb)
  from public.site_banners b where b.tenant_id = p_tenant and b.is_active and public.tenant_today(p_tenant) between b.starts_on and b.ends_on
$$;
create or replace function public.orders_open(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select not coalesce((select orders_paused from public.tenants where id = p_tenant), false)
     and not exists (select 1 from public.site_banners b where b.tenant_id = p_tenant and b.is_active and b.blocks_orders and public.tenant_today(p_tenant) between b.starts_on and b.ends_on)
$$;

-- ---------- hidangan unggulan (maks 6 per restoran) ----------
create or replace function public.enforce_featured_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.archived_at is not null then new.is_featured := false; end if;
  if new.is_featured and (tg_op = 'INSERT' or not old.is_featured) and
     (select count(*) from public.menu_items where tenant_id = new.tenant_id and is_featured and archived_at is null and id <> new.id) >= 6 then
    raise exception 'Maksimal 6 hidangan unggulan' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists menu_items_featured on public.menu_items;
create trigger menu_items_featured before insert or update of is_featured, archived_at on public.menu_items for each row execute function public.enforce_featured_limit();

-- ---------- data publik untuk template ----------
create or replace function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'status', t.status, 'restaurant_type', t.restaurant_type,
    'phone', t.phone, 'whatsapp', t.whatsapp, 'email', t.email, 'maps_url', t.maps_url, 'address', t.address,
    'opening_hours', t.opening_hours, 'primary_color', t.primary_color,
    'theme', t.theme, 'theme_custom', t.theme_custom, 'theme_dark', t.theme_dark, 'timezone', t.timezone,
    'languages', coalesce((select jsonb_agg(l.lang order by l.position) from public.tenant_languages l where l.tenant_id = t.id), '[]'::jsonb),
    'translations', coalesce((select jsonb_object_agg(x.lang, jsonb_build_object('brand_name', x.brand_name, 'tagline', x.tagline))
                              from public.tenant_translations x where x.tenant_id = t.id), '{}'::jsonb))
  from public.tenants t where t.id = p_id
$$;
create or replace function public.site_content_json(p_tenant uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.tenant_is_live(p_tenant) then '{}'::jsonb else jsonb_build_object(
    'texts', coalesce((select jsonb_object_agg(s.key, v.langs) from public.site_texts s
                       cross join lateral (select jsonb_object_agg(x.lang, x.value) as langs from public.site_text_translations x where x.site_text_id = s.id and x.value <> '') v
                       where s.tenant_id = p_tenant and v.langs is not null), '{}'::jsonb),
    'images', coalesce((select jsonb_object_agg(slot, image_key) from public.site_images where tenant_id = p_tenant), '{}'::jsonb),
    'banners', public.live_banners_json(p_tenant),
    'orders_open', public.orders_open(p_tenant),
    'featured', coalesce((select jsonb_agg(m.id order by m.sort, m.created_at) from public.menu_items m where m.tenant_id = p_tenant and m.is_featured and m.is_visible and m.archived_at is null), '[]'::jsonb)) end
$$;
grant execute on function public.site_content_json(uuid) to anon, authenticated;

-- ---------- pesanan: tolak bila ditutup ----------
create or replace function public.place_order(p_tenant uuid, p_token text, p_items jsonb, p_name text, p_note text, p_lang text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table public.restaurant_tables; v_primary text; v_lang text; v_no int; v_order uuid; v_total int; v_req int; v_ok int; v_n int;
begin
  select * into v_table from public.restaurant_tables where tenant_id = p_tenant and token = p_token and is_active;
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_table'; end if;
  if not public.orders_open(p_tenant) then raise exception 'E:closed'; end if;   -- tutup sementara / banner libur yang menutup pemesanan
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then raise exception 'E:empty'; end if;
  if exists (select 1 from public.orders where table_id = v_table.id and created_at > now() - interval '30 seconds') then raise exception 'E:rate_limited'; end if;
  select count(*) into v_n from public.orders where table_id = v_table.id and status in ('new', 'preparing', 'ready') and created_at > now() - interval '12 hours';
  if v_n >= 5 then raise exception 'E:too_many_active'; end if;

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
  insert into public.orders (tenant_id, table_id, table_label, order_no, customer_name, note, total_idr, lang)
    values (p_tenant, v_table.id, v_table.label, lpad(v_no::text, 4, '0'), left(nullif(btrim(p_name), ''), 60), left(nullif(btrim(p_note), ''), 200), v_total, v_lang)
    returning id into v_order;
  insert into public.order_items (order_id, tenant_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total)
    select v_order, p_tenant, id, name, price_idr, qty, price_idr * qty from _ok;
  drop table _req, _ok;
  return jsonb_build_object('order_no', lpad(v_no::text, 4, '0'), 'total_idr', v_total, 'table_label', v_table.label);
end $$;
