-- 01-schema.sql — struktur database multi-restoran. Jalankan SEKALI di Supabase > SQL Editor.
-- Foto TIDAK disimpan di Supabase: tabel hanya menyimpan "image_key" (kunci file di Cloudflare R2).

-- =====================================================================
-- 1. TABEL
-- =====================================================================

-- Daftar bahasa. Satu website maksimal 2 bahasa. Batas karakter berbeda per bahasa.
create table public.languages (
  code text primary key check (code ~ '^[a-z]{2}$'),
  name_english text not null,
  name_native text not null,
  is_available boolean not null default false,   -- hanya bahasa yang aktif di sini yang bisa dipilih restoran
  sort int4 not null default 0,
  max_name int4 not null check (max_name > 0),    -- batas karakter: nama menu
  max_short int4 not null check (max_short > 0),  -- batas karakter: deskripsi singkat
  max_detail int4 not null check (max_detail > 0) -- batas karakter: detail menu
);
insert into public.languages (code, name_english, name_native, is_available, sort, max_name, max_short, max_detail) values
  ('id', 'Indonesian', 'Bahasa Indonesia', true, 10, 60, 160, 700),
  ('en', 'English', 'English', true, 20, 60, 160, 700),
  ('zh', 'Chinese (Simplified)', '简体中文', true, 30, 30, 80, 350),
  ('fr', 'French', 'Français', false, 40, 70, 190, 820),
  ('es', 'Spanish', 'Español', false, 50, 70, 190, 820),
  ('ko', 'Korean', '한국어', false, 60, 35, 90, 400),
  ('ja', 'Japanese', '日本語', false, 70, 35, 90, 400);

create table public.plans (
  code text primary key,
  name text not null,
  price_idr int4 not null default 0 check (price_idr >= 0),
  ai_monthly_limit int4 not null default 100 check (ai_monthly_limit >= 0),
  max_menu_items int4 not null default 100 check (max_menu_items >= 0),
  max_admins int4 not null default 2 check (max_admins >= 1)
);

-- Restoran
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  restaurant_type text not null default 'vegetarian' check (restaurant_type in ('vegan', 'vegetarian', 'umum')),
  status text not null default 'trial' check (status in ('trial', 'active', 'suspended', 'cancelled')),
  phone text, whatsapp text, email text,
  maps_url text,                                   -- tautan Google Maps atau koordinat "lat,lng"
  address text check (char_length(address) <= 300), -- alamat: diisi satu kali, tidak diterjemahkan
  opening_hours jsonb,
  primary_color text,
  -- Opsi menu yang DITAMPILKAN kepada owner/manager (ditentukan master). Opsi lain otomatis dikosongkan.
  admin_default_lang text not null default 'id' check (admin_default_lang in ('id', 'en')),  -- bahasa halaman admin bila pengguna belum memilih
  menu_options text[] not null default array['is_spicy']
    check (menu_options <@ array['has_egg', 'has_onion', 'is_non_halal', 'is_spicy']::text[]),
  created_at timestamptz not null default now()
);

-- Bahasa aktif tiap restoran: posisi 1 = bahasa utama (tanpa awalan di alamat), posisi 2 = bahasa kedua. Maksimal 2.
create table public.tenant_languages (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  lang text not null references public.languages(code),
  position int2 not null check (position in (1, 2)),
  primary key (tenant_id, lang),
  constraint tenant_languages_posisi unique (tenant_id, position) deferrable initially deferred
);

-- Nama brand dan slogan per bahasa
create table public.tenant_translations (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  lang text not null references public.languages(code),
  brand_name text not null check (char_length(btrim(brand_name)) between 1 and 80),
  tagline text check (char_length(tagline) <= 160),
  primary key (tenant_id, lang)
);

create table public.tenant_domains (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  hostname text not null unique check (hostname = lower(hostname)),
  kind text not null default 'custom' check (kind in ('subdomain', 'custom')),
  is_primary boolean not null default false,
  status text not null default 'pending' check (status in ('pending', 'active', 'error')),
  cf_hostname_id text,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index tenant_domains_satu_utama on public.tenant_domains(tenant_id) where is_primary;

-- Role tiap anggota. 'Super Admin' bukan role restoran: itu akun di platform_admins (master).
create table public.tenant_members (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'service' check (role in ('owner', 'manager', 'cashier', 'kitchen', 'service')),
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index tenant_members_user on public.tenant_members(user_id);

-- Master (kamu)
create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.subscriptions (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  plan_code text not null references public.plans(code) on delete restrict,
  status text not null default 'trial' check (status in ('trial', 'active', 'past_due', 'cancelled')),
  current_period_start date,
  current_period_end date,
  notes text
);

create table public.ai_usage (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  month date not null check (month = date_trunc('month', month)::date),
  requests int4 not null default 0 check (requests >= 0),
  tokens_in int4 not null default 0,
  tokens_out int4 not null default 0,
  primary key (tenant_id, month)
);

-- Teks utama website (per bahasa)
create table public.site_texts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  key text not null,
  unique (tenant_id, key),
  unique (tenant_id, id)
);
create table public.site_text_translations (
  site_text_id uuid not null,
  lang text not null references public.languages(code),
  tenant_id uuid not null,
  value text not null default '',
  is_locked boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (site_text_id, lang),
  foreign key (tenant_id, site_text_id) references public.site_texts(tenant_id, id) on delete cascade
);

-- Foto tetap website
create table public.site_images (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  slot text not null,
  image_key text not null,
  updated_at timestamptz not null default now(),
  unique (tenant_id, slot),
  unique (tenant_id, id)
);
create table public.site_image_translations (
  site_image_id uuid not null,
  lang text not null references public.languages(code),
  tenant_id uuid not null,
  alt text not null default '',
  primary key (site_image_id, lang),
  foreign key (tenant_id, site_image_id) references public.site_images(tenant_id, id) on delete cascade
);

-- Kategori menu
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  slug text not null,
  glyph text default '膳',
  sort int4 not null default 0,
  is_visible boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, slug),
  unique (tenant_id, id)
);
create index categories_urutan on public.categories(tenant_id, sort);
create table public.category_translations (
  category_id uuid not null,
  lang text not null references public.languages(code),
  tenant_id uuid not null,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  primary key (category_id, lang),
  foreign key (tenant_id, category_id) references public.categories(tenant_id, id) on delete cascade
);

-- Menu (data bukan teks). Opsi yang tidak berlaku untuk tipe restoran otomatis dikosongkan oleh pemicu.
create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  category_id uuid not null,
  price_idr int4 not null check (price_idr >= 0),
  image_key text,
  has_egg boolean not null default false,       -- mengandung telur (vegetarian)
  has_onion boolean not null default false,     -- mengandung bawang (vegan, vegetarian)
  is_non_halal boolean not null default false,  -- non halal (umum)
  is_spicy boolean not null default false,
  spice_level int2 check (spice_level between 1 and 5),
  is_visible boolean not null default true,
  is_sold_out boolean not null default false,
  sort int4 not null default 0,
  archived_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((is_spicy and spice_level is not null) or (not is_spicy and spice_level is null)),
  unique (tenant_id, id),
  foreign key (tenant_id, category_id) references public.categories(tenant_id, id) on delete restrict
);
create index menu_items_urutan on public.menu_items(tenant_id, category_id, sort);

-- Teks menu per bahasa
create table public.menu_item_translations (
  menu_item_id uuid not null,
  lang text not null references public.languages(code),
  tenant_id uuid not null,
  name text not null check (char_length(btrim(name)) > 0),
  short_description text not null check (char_length(btrim(short_description)) > 0),
  detail_description text,               -- boleh kosong; bila terisi, tampil saat kartu di-hover
  badge text check (char_length(badge) <= 40),
  is_locked boolean not null default false,   -- terkunci bila diedit manual: tidak ditimpa AI
  source text not null default 'manual' check (source in ('manual', 'ai')),
  updated_at timestamptz not null default now(),
  primary key (menu_item_id, lang),
  foreign key (tenant_id, menu_item_id) references public.menu_items(tenant_id, id) on delete cascade
);

-- Meja restoran. Tiap meja punya QR berbeda: token acak (rahasia) ada di alamat QR. Pengunjung tidak bisa membaca tabel ini.
create table public.restaurant_tables (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  label text not null check (char_length(btrim(label)) between 1 and 30),
  token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  is_active boolean not null default true,
  sort int4 not null default 0,
  created_at timestamptz not null default now(),
  unique (tenant_id, label),
  unique (tenant_id, id)
);

-- Penomoran pesanan per restoran (diisi hanya oleh fungsi place_order)
create table public.order_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  last_no int4 not null default 0
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  table_id uuid,
  table_label text not null,                -- salinan nama meja saat memesan
  order_no text not null,
  mode text not null default 'dine_in' check (mode in ('dine_in', 'takeaway')),
  status text not null default 'new' check (status in ('new', 'preparing', 'ready', 'done', 'cancelled')),
  customer_name text check (char_length(customer_name) <= 60),
  note text check (char_length(note) <= 200),
  total_idr int4 not null default 0 check (total_idr >= 0),
  lang text not null default 'id' references public.languages(code),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'paid')),   -- pembayaran hanya dicatat; dibayar di kasir
  payment_method text check (payment_method in ('cash', 'card', 'qris', 'other')),
  paid_at timestamptz,
  paid_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((payment_status = 'paid') = (payment_method is not null)),
  unique (tenant_id, order_no),
  unique (tenant_id, id),
  foreign key (tenant_id, table_id) references public.restaurant_tables(tenant_id, id) on delete set null (table_id)
);
create index orders_terbaru on public.orders(tenant_id, created_at desc);
create index orders_meja on public.orders(table_id, created_at desc);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  menu_item_id uuid,
  name_snapshot text not null,
  price_snapshot int4 not null check (price_snapshot >= 0),
  qty int4 not null default 1 check (qty between 1 and 20),
  line_total int4 not null check (line_total >= 0),
  foreign key (tenant_id, order_id) references public.orders(tenant_id, id) on delete cascade,
  foreign key (tenant_id, menu_item_id) references public.menu_items(tenant_id, id) on delete set null (menu_item_id)
);

-- =====================================================================
-- 2. PEMICU (aturan yang dijaga database)
-- =====================================================================

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger menu_items_touch before update on public.menu_items for each row execute function public.touch_updated_at();
create trigger menu_item_tr_touch before update on public.menu_item_translations for each row execute function public.touch_updated_at();
create trigger site_text_tr_touch before update on public.site_text_translations for each row execute function public.touch_updated_at();
create trigger site_images_touch before update on public.site_images for each row execute function public.touch_updated_at();

-- Hanya bahasa yang tersedia yang boleh dipilih restoran
create function public.check_lang_available() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from public.languages where code = new.lang and is_available) then
    raise exception 'Bahasa % belum tersedia', new.lang using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger tenant_languages_tersedia before insert or update on public.tenant_languages for each row execute function public.check_lang_available();

-- Batas karakter per bahasa
create function public.enforce_translation_limits() returns trigger language plpgsql as $$
declare lim public.languages;
begin
  select * into lim from public.languages where code = new.lang;
  if char_length(new.name) > lim.max_name then
    raise exception 'Nama menu melebihi % karakter (bahasa %)', lim.max_name, new.lang using errcode = 'check_violation'; end if;
  if char_length(new.short_description) > lim.max_short then
    raise exception 'Deskripsi singkat melebihi % karakter (bahasa %)', lim.max_short, new.lang using errcode = 'check_violation'; end if;
  if char_length(coalesce(new.detail_description, '')) > lim.max_detail then
    raise exception 'Detail menu melebihi % karakter (bahasa %)', lim.max_detail, new.lang using errcode = 'check_violation'; end if;
  if new.detail_description is not null and btrim(new.detail_description) = '' then new.detail_description = null; end if;
  return new;
end $$;
create trigger menu_item_tr_batas before insert or update on public.menu_item_translations for each row execute function public.enforce_translation_limits();

-- Opsi menu mengikuti pengaturan master (tenants.menu_options); opsi yang tidak diaktifkan otomatis dikosongkan.
create function public.normalize_menu_options() returns trigger language plpgsql as $$
declare v_opts text[];
begin
  select menu_options into v_opts from public.tenants where id = new.tenant_id;
  if not ('has_egg' = any(v_opts)) then new.has_egg = false; end if;
  if not ('has_onion' = any(v_opts)) then new.has_onion = false; end if;
  if not ('is_non_halal' = any(v_opts)) then new.is_non_halal = false; end if;
  if not ('is_spicy' = any(v_opts)) then new.is_spicy = false; end if;
  if not new.is_spicy then new.spice_level = null; end if;
  return new;
end $$;
create function public.prevent_slug_change() returns trigger language plpgsql as $$
begin
  if new.slug is distinct from old.slug then raise exception 'Slug restoran tidak boleh diubah (dipakai di jalur foto)' using errcode = 'check_violation'; end if;
  return new;
end $$;
create trigger tenants_slug_tetap before update of slug on public.tenants for each row execute function public.prevent_slug_change();

create trigger menu_items_opsi before insert or update on public.menu_items for each row execute function public.normalize_menu_options();

-- Bila tipe atau opsi menu diubah, data menu yang lama ikut dirapikan
create function public.renormalize_items() returns trigger language plpgsql as $$
begin update public.menu_items set updated_at = now() where tenant_id = new.id; return new; end $$;
create trigger tenants_opsi_berubah after update of restaurant_type, menu_options on public.tenants for each row when (old.menu_options is distinct from new.menu_options) execute function public.renormalize_items();

-- =====================================================================
-- 3. FUNGSI BANTU
-- =====================================================================

create function public.is_platform_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;
create function public.is_member(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_platform_admin() or exists (select 1 from public.tenant_members where tenant_id = p_tenant and user_id = auth.uid())
$$;
-- Role pemanggil di sebuah restoran: 'super_admin' (master) | owner | manager | cashier | kitchen | service | null
create function public.tenant_role(p_tenant uuid) returns text language sql stable security definer set search_path = public as $$
  select case when public.is_platform_admin() then 'super_admin'
              else (select role from public.tenant_members where tenant_id = p_tenant and user_id = auth.uid()) end
$$;
create function public.has_role(p_tenant uuid, p_roles text[]) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.tenant_role(p_tenant) = 'super_admin' or public.tenant_role(p_tenant) = any(p_roles), false)
$$;
create function public.is_owner(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(p_tenant, array['owner'])
$$;
-- Boleh mengelola menu & kategori: super admin, owner, manager
create function public.can_edit_menu(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(p_tenant, array['owner', 'manager'])
$$;
-- Siapa boleh MEMBUAT akun role apa: super admin → semua | owner → manager, cashier, kitchen, service | manager → kitchen, service
create function public.can_create_role(p_tenant uuid, p_role text) returns boolean language sql stable security definer set search_path = public as $$
  select case public.tenant_role(p_tenant)
    when 'super_admin' then p_role in ('owner', 'manager', 'cashier', 'kitchen', 'service')
    when 'owner' then p_role in ('manager', 'cashier', 'kitchen', 'service')
    when 'manager' then p_role in ('kitchen', 'service')
    else false end
$$;
-- Siapa boleh mengubah/mereset kata sandi siapa (bukan diri sendiri):
--   super admin → semua | owner → manager, cashier, kitchen, service | manager → kitchen, service | lainnya → tidak ada
create function public.can_reset_password(p_tenant uuid, p_target uuid) returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_actor text := public.tenant_role(p_tenant); v_target text;
begin
  if v_actor is null or p_target = auth.uid() then return false; end if;
  select role into v_target from public.tenant_members where tenant_id = p_tenant and user_id = p_target;
  if v_target is null then return false; end if;
  return case v_actor
    when 'super_admin' then true
    when 'owner' then v_target in ('manager', 'cashier', 'kitchen', 'service')
    when 'manager' then v_target in ('kitchen', 'service')
    else false end;
end $$;
create function public.tenant_is_live(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.tenants where id = p_tenant and status in ('trial', 'active'))
$$;
create function public.menu_item_is_public(p_item uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.menu_items m where m.id = p_item and m.is_visible and m.archived_at is null and public.tenant_is_live(m.tenant_id))
$$;
create function public.category_is_public(p_cat uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.categories c where c.id = p_cat and c.is_visible and public.tenant_is_live(c.tenant_id))
$$;

-- Data publik satu restoran (untuk website)
create function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'status', t.status, 'restaurant_type', t.restaurant_type,
    'phone', t.phone, 'whatsapp', t.whatsapp, 'email', t.email, 'maps_url', t.maps_url, 'address', t.address,
    'opening_hours', t.opening_hours, 'primary_color', t.primary_color,
    'languages', coalesce((select jsonb_agg(l.lang order by l.position) from public.tenant_languages l where l.tenant_id = t.id), '[]'::jsonb),
    'translations', coalesce((select jsonb_object_agg(x.lang, jsonb_build_object('brand_name', x.brand_name, 'tagline', x.tagline))
                              from public.tenant_translations x where x.tenant_id = t.id), '{}'::jsonb))
  from public.tenants t where t.id = p_id
$$;

-- Mencari restoran dari domain (atau slug cadangan untuk pengembangan)
create function public.resolve_tenant(p_host text, p_slug text default null) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  select d.tenant_id into v_id from public.tenant_domains d where d.hostname = lower(p_host) and d.status = 'active' limit 1;
  if v_id is null and p_slug is not null then select id into v_id from public.tenants where slug = p_slug; end if;
  if v_id is null then return null; end if;
  return public.tenant_public_json(v_id);
end $$;

-- Mencatat satu permintaan terjemahan AI; false bila bukan anggota, tanpa langganan aktif, atau kuota bulan ini habis
create function public.consume_ai(p_tenant uuid, p_tokens_in int default 0, p_tokens_out int default 0) returns boolean language plpgsql security definer set search_path = public as $$
declare v_limit int; v_month date := date_trunc('month', now())::date; v_rows int;
begin
  if not public.can_edit_menu(p_tenant) then return false; end if;
  select p.ai_monthly_limit into v_limit from public.subscriptions s join public.plans p on p.code = s.plan_code
   where s.tenant_id = p_tenant and s.status in ('trial', 'active');
  if v_limit is null then return false; end if;
  insert into public.ai_usage (tenant_id, month) values (p_tenant, v_month) on conflict do nothing;
  update public.ai_usage set requests = requests + 1, tokens_in = tokens_in + p_tokens_in, tokens_out = tokens_out + p_tokens_out
   where tenant_id = p_tenant and month = v_month and requests < v_limit;
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end $$;

-- HANYA MASTER: tipe restoran, bahasa aktif (1 atau 2; yang pertama = bahasa utama), dan opsi menu yang ditampilkan ke owner/manager
create function public.master_set_tenant_settings(p_tenant uuid, p_type text, p_langs text[], p_options text[], p_admin_lang text default 'id') returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.is_platform_admin() then raise exception 'Hanya master yang boleh mengubah pengaturan ini' using errcode = '42501'; end if;
  if p_type not in ('vegan', 'vegetarian', 'umum') then raise exception 'Tipe restoran tidak valid' using errcode = 'check_violation'; end if;
  if p_langs is null or cardinality(p_langs) not between 1 and 2 then raise exception 'Pilih 1 atau 2 bahasa' using errcode = 'check_violation'; end if;
  if cardinality(p_langs) = 2 and p_langs[1] = p_langs[2] then raise exception 'Bahasa tidak boleh sama' using errcode = 'check_violation'; end if;
  update public.tenants set restaurant_type = p_type, menu_options = coalesce(p_options, '{}'), admin_default_lang = coalesce(p_admin_lang, 'id') where id = p_tenant;  -- check constraint menolak opsi tidak dikenal
  if not found then raise exception 'Restoran tidak ditemukan'; end if;
  delete from public.tenant_languages where tenant_id = p_tenant;
  for i in 1 .. cardinality(p_langs) loop
    insert into public.tenant_languages (tenant_id, lang, position) values (p_tenant, p_langs[i], i);
  end loop;
end $$;

-- Daftar anggota + email (untuk super admin, owner, manager). can_reset = boleh mengubah kata sandi orang itu.
create function public.list_tenant_members(p_tenant uuid) returns table (user_id uuid, email text, role text, created_at timestamptz, can_reset boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner', 'manager']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  return query select m.user_id, u.email::text, m.role, m.created_at, public.can_reset_password(p_tenant, m.user_id)
    from public.tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = p_tenant
    order by array_position(array['owner', 'manager', 'cashier', 'kitchen', 'service'], m.role), u.email;
end $$;

-- HANYA MASTER: menghubungkan akun yang sudah ada (berdasarkan email) ke restoran, atau mencabut akses
create function public.master_link_member(p_tenant uuid, p_email text, p_role text) returns uuid language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if not public.is_platform_admin() then raise exception 'Hanya master' using errcode = '42501'; end if;
  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then raise exception 'Email belum terdaftar' using errcode = 'no_data_found'; end if;
  insert into public.tenant_members (tenant_id, user_id, role) values (p_tenant, v_user, p_role)
  on conflict (tenant_id, user_id) do update set role = excluded.role;
  return v_user;
end $$;
create function public.master_remove_member(p_tenant uuid, p_user uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Hanya master' using errcode = '42501'; end if;
  delete from public.tenant_members where tenant_id = p_tenant and user_id = p_user;
end $$;

-- Tandai menu habis/tersedia: super admin, owner, manager, kitchen
create function public.set_sold_out(p_item uuid, p_value boolean) returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.menu_items where id = p_item;
  if v_tenant is null or not public.has_role(v_tenant, array['owner', 'manager', 'kitchen']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  update public.menu_items set is_sold_out = p_value where id = p_item;
end $$;

-- Urutan hasil drag and drop (berjalan dengan hak pengguna: aturan akses tetap berlaku)
create function public.reorder_categories(p_tenant uuid, p_ids uuid[]) returns void language sql set search_path = public as $$
  update public.categories c set sort = o.ord::int * 10 from unnest(p_ids) with ordinality as o(id, ord) where c.id = o.id and c.tenant_id = p_tenant
$$;
create function public.reorder_menu_items(p_tenant uuid, p_category uuid, p_ids uuid[]) returns void language sql set search_path = public as $$
  update public.menu_items m set sort = o.ord::int * 10 from unnest(p_ids) with ordinality as o(id, ord) where m.id = o.id and m.tenant_id = p_tenant and m.category_id = p_category
$$;

-- Ganti QR meja (token lama langsung tidak berlaku)
create function public.rotate_table_token(p_table uuid) returns text language plpgsql set search_path = public as $$
declare v_token text := replace(gen_random_uuid()::text, '-', '');
begin
  update public.restaurant_tables set token = v_token where id = p_table;
  if not found then raise exception 'Meja tidak ditemukan atau akses ditolak' using errcode = '42501'; end if;
  return v_token;
end $$;

-- Halaman Order (publik): meja dari token QR. null bila token salah, meja nonaktif, atau token milik restoran lain.
create function public.resolve_table(p_tenant uuid, p_token text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('label', t.label) from public.restaurant_tables t
   where t.tenant_id = p_tenant and t.token = p_token and t.is_active and public.tenant_is_live(t.tenant_id)
$$;

-- Pesanan dari pelanggan (dipanggil server; harga SELALU dihitung ulang dari database).
-- Kode galat: E:invalid_table | E:empty | E:rate_limited | E:too_many_active | E:item_unavailable
create function public.place_order(p_tenant uuid, p_token text, p_items jsonb, p_name text, p_note text, p_lang text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table public.restaurant_tables; v_primary text; v_lang text; v_no int; v_order uuid; v_total int; v_req int; v_ok int; v_n int;
begin
  select * into v_table from public.restaurant_tables where tenant_id = p_tenant and token = p_token and is_active;
  if not found or not public.tenant_is_live(p_tenant) then raise exception 'E:invalid_table'; end if;
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

-- Status pesanan menurut role: kitchen → diproses/siap | service → selesai (dari siap) | cashier, manager, owner, super admin → semua
create function public.set_order_status(p_order uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_old text; v_role text; v_ok boolean;
begin
  if p_status not in ('new', 'preparing', 'ready', 'done', 'cancelled') then raise exception 'Status tidak valid' using errcode = 'check_violation'; end if;
  select tenant_id, status into v_tenant, v_old from public.orders where id = p_order;
  v_role := public.tenant_role(v_tenant);
  v_ok := case when v_role in ('super_admin', 'owner', 'manager', 'cashier') then true
               when v_role = 'kitchen' then p_status in ('preparing', 'ready') and v_old in ('new', 'preparing')
               when v_role = 'service' then p_status = 'done' and v_old = 'ready'
               else false end;
  if v_tenant is null or not v_ok then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  update public.orders set status = p_status where id = p_order;
end $$;

-- Catat pembayaran (dibayar di kasir). p_method null = batalkan tanda dibayar. Cashier, manager, owner, super admin.
create function public.set_order_payment(p_order uuid, p_method text) returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.orders where id = p_order;
  if v_tenant is null or not public.has_role(v_tenant, array['owner', 'manager', 'cashier']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_method is not null and p_method not in ('cash', 'card', 'qris', 'other') then raise exception 'Metode tidak valid' using errcode = 'check_violation'; end if;
  update public.orders set payment_status = case when p_method is null then 'unpaid' else 'paid' end, payment_method = p_method,
    paid_at = case when p_method is null then null else now() end, paid_by = case when p_method is null then null else auth.uid() end where id = p_order;
end $$;

-- Simpan menu + terjemahannya dalam satu langkah (berjalan dengan hak pengguna, jadi aturan akses tetap berlaku)
create function public.save_menu_item(p jsonb) returns uuid language plpgsql set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_tenant uuid := (p->>'tenant_id')::uuid; v_cat uuid := (p->>'category_id')::uuid;
        v_spicy boolean := coalesce((p->>'is_spicy')::boolean, false); v_level int2 := nullif(p->>'spice_level', '')::int2; t jsonb;
begin
  if v_id is null then
    insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, has_onion, is_non_halal, is_spicy, spice_level, is_visible, is_sold_out, sort, created_by)
    values (v_tenant, v_cat, (p->>'price_idr')::int, nullif(p->>'image_key', ''),
      coalesce((p->>'has_egg')::boolean, false), coalesce((p->>'has_onion')::boolean, false), coalesce((p->>'is_non_halal')::boolean, false),
      v_spicy, case when v_spicy then coalesce(v_level, 1) else null end,
      coalesce((p->>'is_visible')::boolean, true), coalesce((p->>'is_sold_out')::boolean, false),
      (select coalesce(max(sort), 0) + 10 from public.menu_items where tenant_id = v_tenant and category_id = v_cat), auth.uid())
    returning id into v_id;
  else
    update public.menu_items set category_id = v_cat, price_idr = (p->>'price_idr')::int, image_key = nullif(p->>'image_key', ''),
      has_egg = coalesce((p->>'has_egg')::boolean, false), has_onion = coalesce((p->>'has_onion')::boolean, false), is_non_halal = coalesce((p->>'is_non_halal')::boolean, false),
      is_spicy = v_spicy, spice_level = case when v_spicy then coalesce(v_level, 1) else null end,
      is_visible = coalesce((p->>'is_visible')::boolean, true), is_sold_out = coalesce((p->>'is_sold_out')::boolean, false)
     where id = v_id and tenant_id = v_tenant;
    if not found then raise exception 'Menu tidak ditemukan atau akses ditolak' using errcode = '42501'; end if;
  end if;
  for t in select * from jsonb_array_elements(coalesce(p->'tr', '[]'::jsonb)) loop
    insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge, is_locked, source)
    values (v_id, t->>'lang', v_tenant, t->>'name', t->>'short_description', nullif(t->>'detail_description', ''), nullif(t->>'badge', ''),
            coalesce((t->>'is_locked')::boolean, false), coalesce(t->>'source', 'manual'))
    on conflict (menu_item_id, lang) do update set name = excluded.name, short_description = excluded.short_description,
      detail_description = excluded.detail_description, badge = excluded.badge, is_locked = excluded.is_locked, source = excluded.source;
  end loop;
  return v_id;
end $$;

-- Simpan kategori + terjemahan nama
create function public.save_category(p jsonb) returns uuid language plpgsql set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_tenant uuid := (p->>'tenant_id')::uuid; t jsonb;
begin
  if v_id is null then
    insert into public.categories (tenant_id, slug, glyph, is_visible, sort)
    values (v_tenant, p->>'slug', coalesce(nullif(p->>'glyph', ''), '膳'), coalesce((p->>'is_visible')::boolean, true),
            (select coalesce(max(sort), 0) + 10 from public.categories where tenant_id = v_tenant))
    returning id into v_id;
  else
    update public.categories set glyph = coalesce(nullif(p->>'glyph', ''), '膳'), is_visible = coalesce((p->>'is_visible')::boolean, true)
     where id = v_id and tenant_id = v_tenant;
    if not found then raise exception 'Kategori tidak ditemukan atau akses ditolak' using errcode = '42501'; end if;
  end if;
  for t in select * from jsonb_array_elements(coalesce(p->'tr', '[]'::jsonb)) loop
    insert into public.category_translations (category_id, lang, tenant_id, name) values (v_id, t->>'lang', v_tenant, t->>'name')
    on conflict (category_id, lang) do update set name = excluded.name;
  end loop;
  return v_id;
end $$;

-- =====================================================================
-- 4. ATURAN AKSES (Row Level Security)
-- =====================================================================
alter table public.languages enable row level security;
alter table public.plans enable row level security;
alter table public.tenants enable row level security;
alter table public.tenant_languages enable row level security;
alter table public.tenant_translations enable row level security;
alter table public.tenant_domains enable row level security;
alter table public.tenant_members enable row level security;
alter table public.platform_admins enable row level security;
alter table public.subscriptions enable row level security;
alter table public.ai_usage enable row level security;
alter table public.site_texts enable row level security;
alter table public.site_text_translations enable row level security;
alter table public.site_images enable row level security;
alter table public.site_image_translations enable row level security;
alter table public.categories enable row level security;
alter table public.category_translations enable row level security;
alter table public.menu_items enable row level security;
alter table public.menu_item_translations enable row level security;
alter table public.restaurant_tables enable row level security;
alter table public.order_counters enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Data referensi & internal
create policy "baca bahasa" on public.languages for select to anon, authenticated using (true);
create policy "baca paket" on public.plans for select to authenticated using (true);
create policy "baca restoran sendiri" on public.tenants for select to authenticated using (public.is_member(id));
create policy "owner ubah profil" on public.tenants for update to authenticated using (public.is_owner(id)) with check (public.is_owner(id));
create policy "baca bahasa restoran" on public.tenant_languages for select to authenticated using (public.is_member(tenant_id));
create policy "baca domain sendiri" on public.tenant_domains for select to authenticated using (public.is_member(tenant_id));
create policy "baca anggota" on public.tenant_members for select to authenticated using (user_id = auth.uid() or public.is_owner(tenant_id));
create policy "baca diri sendiri" on public.platform_admins for select to authenticated using (user_id = auth.uid());
create policy "baca langganan sendiri" on public.subscriptions for select to authenticated using (public.is_member(tenant_id));
create policy "baca pemakaian AI sendiri" on public.ai_usage for select to authenticated using (public.is_member(tenant_id));
create policy "baca pesanan sendiri" on public.orders for select to authenticated using (public.is_member(tenant_id));
create policy "baca meja sendiri" on public.restaurant_tables for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola meja" on public.restaurant_tables for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
-- status & pembayaran pesanan hanya lewat fungsi set_order_status / set_order_payment
create policy "baca isi pesanan sendiri" on public.order_items for select to authenticated using (public.is_member(tenant_id));

-- Owner hanya boleh mengubah profil kontak. Tipe restoran, bahasa, opsi menu, status, domain, dan paket hanya lewat master.
revoke update on public.tenants from anon, authenticated;
grant update (phone, whatsapp, email, maps_url, address, opening_hours, primary_color) on public.tenants to authenticated;

-- Isi website: pengunjung membaca (hanya restoran aktif), anggota mengelola
create policy "publik baca nama restoran" on public.tenant_translations for select to anon, authenticated using (public.tenant_is_live(tenant_id));
create policy "baca nama restoran sendiri" on public.tenant_translations for select to authenticated using (public.is_member(tenant_id));
create policy "owner kelola nama restoran" on public.tenant_translations for all to authenticated using (public.is_owner(tenant_id)) with check (public.is_owner(tenant_id));
create policy "publik baca teks" on public.site_texts for select to anon, authenticated using (public.tenant_is_live(tenant_id));
create policy "baca teks sendiri" on public.site_texts for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola teks" on public.site_texts for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca terjemahan teks" on public.site_text_translations for select to anon, authenticated using (public.tenant_is_live(tenant_id));
create policy "baca terjemahan teks sendiri" on public.site_text_translations for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola terjemahan teks" on public.site_text_translations for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca foto situs" on public.site_images for select to anon, authenticated using (public.tenant_is_live(tenant_id));
create policy "baca foto situs sendiri" on public.site_images for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola foto situs" on public.site_images for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca alt foto" on public.site_image_translations for select to anon, authenticated using (public.tenant_is_live(tenant_id));
create policy "baca alt foto sendiri" on public.site_image_translations for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola alt foto" on public.site_image_translations for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca kategori" on public.categories for select to anon, authenticated using (public.tenant_is_live(tenant_id) and is_visible);
create policy "baca kategori sendiri" on public.categories for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola kategori" on public.categories for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca nama kategori" on public.category_translations for select to anon, authenticated using (public.category_is_public(category_id));
create policy "baca nama kategori sendiri" on public.category_translations for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola nama kategori" on public.category_translations for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca menu" on public.menu_items for select to anon, authenticated using (public.tenant_is_live(tenant_id) and is_visible and archived_at is null);
create policy "baca menu sendiri" on public.menu_items for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola menu" on public.menu_items for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
create policy "publik baca teks menu" on public.menu_item_translations for select to anon, authenticated using (public.menu_item_is_public(menu_item_id));
create policy "baca teks menu sendiri" on public.menu_item_translations for select to authenticated using (public.is_member(tenant_id));
create policy "owner manager kelola teks menu" on public.menu_item_translations for all to authenticated using (public.can_edit_menu(tenant_id)) with check (public.can_edit_menu(tenant_id));
