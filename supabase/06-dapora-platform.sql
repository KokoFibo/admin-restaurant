-- 06-dapora-platform.sql — fondasi SaaS Dapora (aman diulang). Jalankan SETELAH 05-tampilan.sql.
-- Isi: pengaturan domain dasar, tabel template, slug cadangan, subdomain bawaan otomatis lewat tenant_domains,
--      pengaman domain kustom, create_tenant() (hanya service_role), slug_available() (untuk form daftar).

-- ---------- pengaturan platform ----------
create table if not exists public.platform_settings (key text primary key, value text not null);
alter table public.platform_settings enable row level security;   -- tanpa policy: hanya fungsi security definer / service_role
insert into public.platform_settings (key, value) values ('base_domain', 'kokofibo.it.com') on conflict (key) do nothing;

-- ---------- template ----------
create table if not exists public.templates (
  id text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null,
  description text,
  preview_image text,
  restaurant_types text[] not null default array['vegan', 'vegetarian', 'umum'],
  is_active boolean not null default true,
  sort int4 not null default 0
);
alter table public.templates enable row level security;
drop policy if exists "publik baca template" on public.templates;
create policy "publik baca template" on public.templates for select to anon, authenticated using (is_active);
insert into public.templates (id, name, description, sort) values ('aisin', 'Aisin', 'Tenang dan elegan, cocok untuk restoran vegetarian/vegan.', 1) on conflict (id) do nothing;

alter table public.tenants add column if not exists template_id text not null default 'aisin' references public.templates(id);

-- ---------- slug cadangan (tidak boleh jadi subdomain restoran) ----------
create table if not exists public.reserved_slugs (slug text primary key);
alter table public.reserved_slugs enable row level security;
insert into public.reserved_slugs (slug) values
  ('admin'), ('www'), ('api'), ('app'), ('dashboard'), ('login'), ('signup'), ('auth'), ('mail'), ('smtp'), ('imap'), ('ftp'),
  ('cdn'), ('static'), ('assets'), ('images'), ('media'), ('status'), ('support'), ('help'), ('docs'), ('blog'), ('billing'),
  ('dapora'), ('cname'), ('proxy'), ('staging'), ('dev'), ('test'), ('demo'), ('preview')
on conflict do nothing;

create or replace function public.tenants_cek_slug() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.reserved_slugs r where r.slug = new.slug) then
    raise exception 'Slug "%" dicadangkan sistem', new.slug using errcode = 'check_violation';
  end if;
  if char_length(new.slug) not between 3 and 40 then
    raise exception 'Slug harus 3–40 karakter' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists tenants_slug_dicek on public.tenants;
create trigger tenants_slug_dicek before insert on public.tenants for each row execute function public.tenants_cek_slug();

-- ---------- subdomain bawaan: <slug>.<base_domain> masuk tenant_domains otomatis ----------
create or replace function public.tenants_domain_bawaan() returns trigger language plpgsql security definer set search_path = public as $$
declare v_base text;
begin
  select value into v_base from public.platform_settings where key = 'base_domain';
  if v_base is null then return new; end if;
  insert into public.tenant_domains (tenant_id, hostname, kind, is_primary, status, verified_at)
  values (new.id, new.slug || '.' || v_base, 'subdomain', not exists (select 1 from public.tenant_domains d where d.tenant_id = new.id and d.is_primary), 'active', now())
  on conflict (hostname) do nothing;
  return new;
end $$;
drop trigger if exists tenants_domain_bawaan_dibuat on public.tenants;
create trigger tenants_domain_bawaan_dibuat after insert on public.tenants for each row execute function public.tenants_domain_bawaan();

-- isi ulang untuk restoran yang sudah ada (mis. aisin)
insert into public.tenant_domains (tenant_id, hostname, kind, is_primary, status, verified_at)
select t.id, t.slug || '.' || b.value, 'subdomain',
       not exists (select 1 from public.tenant_domains d where d.tenant_id = t.id and d.is_primary), 'active', now()
from public.tenants t cross join (select value from public.platform_settings where key = 'base_domain') b
where not exists (select 1 from public.tenant_domains d where d.tenant_id = t.id and d.kind = 'subdomain')
on conflict (hostname) do nothing;

-- ---------- pengaman: domain kustom tidak boleh menyamar sebagai domain platform ----------
create or replace function public.tenant_domains_cek() returns trigger language plpgsql security definer set search_path = public as $$
declare v_base text; v_slug text;
begin
  select value into v_base from public.platform_settings where key = 'base_domain';
  if new.kind = 'custom' then
    if new.hostname like '%*%' then raise exception 'Domain wildcard tidak didukung' using errcode = 'check_violation'; end if;
    if v_base is not null and (new.hostname = v_base or new.hostname like '%.' || v_base) then
      raise exception 'Domain kustom tidak boleh berada di bawah %', v_base using errcode = 'check_violation';
    end if;
  else
    select slug into v_slug from public.tenants where id = new.tenant_id;
    if v_base is null or new.hostname <> v_slug || '.' || v_base then
      raise exception 'Subdomain bawaan harus <slug>.<base_domain>' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists tenant_domains_dicek on public.tenant_domains;
create trigger tenant_domains_dicek before insert or update of hostname, kind on public.tenant_domains for each row execute function public.tenant_domains_cek();

-- ---------- data publik: tambah template_id ----------
create or replace function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'status', t.status, 'restaurant_type', t.restaurant_type, 'template_id', t.template_id,
    'phone', t.phone, 'whatsapp', t.whatsapp, 'email', t.email, 'maps_url', t.maps_url, 'address', t.address,
    'opening_hours', t.opening_hours, 'primary_color', t.primary_color,
    'languages', coalesce((select jsonb_agg(l.lang order by l.position) from public.tenant_languages l where l.tenant_id = t.id), '[]'::jsonb),
    'translations', coalesce((select jsonb_object_agg(x.lang, jsonb_build_object('brand_name', x.brand_name, 'tagline', x.tagline))
                              from public.tenant_translations x where x.tenant_id = t.id), '{}'::jsonb))
  from public.tenants t where t.id = p_id
$$;
-- CATATAN: bila 05-tampilan.sql sudah mendefinisikan ulang tenant_public_json, gabungkan kunci 'template_id' ke versi terbaru itu.

-- ---------- form daftar: slug tersedia? ----------
create or replace function public.slug_available(p_slug text) returns boolean language sql stable security definer set search_path = public as $$
  select p_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(p_slug) between 3 and 40
     and not exists (select 1 from public.reserved_slugs where slug = p_slug)
     and not exists (select 1 from public.tenants where slug = p_slug)
$$;
grant execute on function public.slug_available(text) to anon, authenticated;

-- ---------- buat restoran baru (HANYA dari server dengan service_role) ----------
create or replace function public.create_tenant(
  p_owner uuid, p_slug text, p_brand text, p_template text default 'aisin',
  p_type text default 'umum', p_lang text default 'id', p_plan text default 'basic'
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not exists (select 1 from auth.users where id = p_owner) then raise exception 'Pemilik tidak ditemukan'; end if;
  if not exists (select 1 from public.templates where id = p_template and is_active) then raise exception 'Template tidak tersedia'; end if;
  insert into public.tenants (slug, restaurant_type, template_id) values (lower(p_slug), p_type, p_template) returning id into v_id;  -- trigger membuat <slug>.<base_domain>
  insert into public.tenant_languages (tenant_id, lang, position) values (v_id, p_lang, 1);
  insert into public.tenant_translations (tenant_id, lang, brand_name) values (v_id, p_lang, btrim(p_brand));
  insert into public.tenant_members (tenant_id, user_id, role) values (v_id, p_owner, 'owner');
  insert into public.subscriptions (tenant_id, plan_code, status, current_period_start, current_period_end)
  values (v_id, p_plan, 'trial', current_date, current_date + 14);
  return v_id;
end $$;
revoke all on function public.create_tenant(uuid, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.create_tenant(uuid, text, text, text, text, text, text) to service_role;

-- ---------- pindah domain dasar (mis. kokofibo.it.com → dapora.com) ----------
-- Jalankan HANYA setelah wildcard DNS + Worker route untuk domain baru aktif. Domain kustom pelanggan tidak berubah.
-- Pemakaian:  select public.rebase_subdomains('dapora.com');
create or replace function public.rebase_subdomains(p_new_base text) returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_new_base !~ '^[a-z0-9]+([.-][a-z0-9]+)*\.[a-z]{2,}$' then raise exception 'Domain dasar tidak valid'; end if;
  update public.platform_settings set value = p_new_base where key = 'base_domain';   -- dulu: trigger pengaman memakai nilai ini
  update public.tenant_domains d set hostname = t.slug || '.' || p_new_base
    from public.tenants t where t.id = d.tenant_id and d.kind = 'subdomain';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.rebase_subdomains(text) from public, anon, authenticated;
grant execute on function public.rebase_subdomains(text) to service_role;
