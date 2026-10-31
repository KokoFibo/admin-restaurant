-- 04-peran.sql — aturan peran final (jalankan SETELAH 01–03; aman dijalankan ulang).
--  • Hanya OWNER (dan Super Admin) membuat/mereset/menonaktifkan/menghapus akun staf. Manager tidak lagi.
--  • Hanya OWNER mengubah teks & foto hero website.
--  • Akun bisa dinonaktifkan (is_active). Staf hanya boleh di SATU restoran; owner boleh banyak restoran.
--  • Slug admin/www/api dilarang (bentrok dengan admin.<domain>).

alter table public.tenant_members add column if not exists is_active boolean not null default true;

-- Akun nonaktif kehilangan akses data seketika (JWT yang masih hidup pun tidak berguna).
create or replace function public.is_member(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.is_platform_admin() or exists (select 1 from public.tenant_members where tenant_id = p_tenant and user_id = auth.uid() and is_active)
$$;
create or replace function public.tenant_role(p_tenant uuid) returns text language sql stable security definer set search_path = public as $$
  select case when public.is_platform_admin() then 'super_admin'
              else (select role from public.tenant_members where tenant_id = p_tenant and user_id = auth.uid() and is_active) end
$$;

-- Siapa boleh MEMBUAT akun role apa: super admin → semua | owner → manager, cashier, kitchen, service | lainnya → tidak ada
create or replace function public.can_create_role(p_tenant uuid, p_role text) returns boolean language sql stable security definer set search_path = public as $$
  select case public.tenant_role(p_tenant)
    when 'super_admin' then p_role in ('owner', 'manager', 'cashier', 'kitchen', 'service')
    when 'owner' then p_role in ('manager', 'cashier', 'kitchen', 'service')
    else false end
$$;
-- Siapa boleh mengubah kata sandi / menonaktifkan / menghapus akun lain (bukan diri sendiri): super admin → semua | owner → staf | lainnya → tidak ada
create or replace function public.can_reset_password(p_tenant uuid, p_target uuid) returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_actor text := public.tenant_role(p_tenant); v_target text;
begin
  if v_actor is null or p_target = auth.uid() then return false; end if;
  select role into v_target from public.tenant_members where tenant_id = p_tenant and user_id = p_target;
  if v_target is null then return false; end if;
  return case v_actor
    when 'super_admin' then true
    when 'owner' then v_target in ('manager', 'cashier', 'kitchen', 'service')
    else false end;
end $$;
create or replace function public.can_manage_account(p_tenant uuid, p_target uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.can_reset_password(p_tenant, p_target)
$$;

-- Hanya owner (dan super admin) yang boleh mengubah tampilan website (hero)
create or replace function public.can_edit_site(p_tenant uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(p_tenant, array['owner'])
$$;
drop policy if exists "owner manager kelola teks" on public.site_texts;
drop policy if exists "owner kelola teks" on public.site_texts;
create policy "owner kelola teks" on public.site_texts for all to authenticated using (public.can_edit_site(tenant_id)) with check (public.can_edit_site(tenant_id));
drop policy if exists "owner manager kelola terjemahan teks" on public.site_text_translations;
drop policy if exists "owner kelola terjemahan teks" on public.site_text_translations;
create policy "owner kelola terjemahan teks" on public.site_text_translations for all to authenticated using (public.can_edit_site(tenant_id)) with check (public.can_edit_site(tenant_id));
drop policy if exists "owner manager kelola foto situs" on public.site_images;
drop policy if exists "owner kelola foto situs" on public.site_images;
create policy "owner kelola foto situs" on public.site_images for all to authenticated using (public.can_edit_site(tenant_id)) with check (public.can_edit_site(tenant_id));

-- Daftar akun restoran: hanya owner & super admin
drop function if exists public.list_tenant_members(uuid);
create function public.list_tenant_members(p_tenant uuid) returns table (user_id uuid, email text, role text, created_at timestamptz, can_reset boolean, is_active boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  return query select m.user_id, u.email::text, m.role, m.created_at, public.can_manage_account(p_tenant, m.user_id), m.is_active
    from public.tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = p_tenant
    order by array_position(array['owner', 'manager', 'cashier', 'kitchen', 'service'], m.role), u.email;
end $$;

-- Staf (manager/cashier/kitchen/service) hanya boleh di satu restoran; owner boleh banyak restoran tetapi tidak merangkap staf di tempat lain.
create or replace function public.enforce_staff_single_tenant() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role <> 'owner' then
    if exists (select 1 from public.tenant_members where user_id = new.user_id and tenant_id <> new.tenant_id) then
      raise exception 'Akun staf hanya boleh terdaftar di satu restoran' using errcode = 'check_violation'; end if;
  elsif exists (select 1 from public.tenant_members where user_id = new.user_id and tenant_id <> new.tenant_id and role <> 'owner') then
    raise exception 'Akun ini staf di restoran lain; tidak bisa dijadikan owner' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists tenant_members_staf_satu on public.tenant_members;
create trigger tenant_members_staf_satu before insert or update of tenant_id, user_id, role on public.tenant_members for each row execute function public.enforce_staff_single_tenant();

-- Slug yang dipakai sistem
alter table public.tenants drop constraint if exists tenants_slug_dilarang;
alter table public.tenants add constraint tenants_slug_dilarang check (slug not in ('admin', 'www', 'api')) not valid;

-- Restoran mana saja yang terdampak bila sebuah akun owner dihapus; sole = dia owner aktif satu-satunya. Hanya server (service_role).
create or replace function public.owner_impact(p_user uuid) returns table (slug text, sole boolean) language sql stable security definer set search_path = public as $$
  select t.slug, not exists (select 1 from public.tenant_members o where o.tenant_id = m.tenant_id and o.role = 'owner' and o.user_id <> p_user and o.is_active)
  from public.tenant_members m join public.tenants t on t.id = m.tenant_id where m.user_id = p_user and m.role = 'owner' order by t.slug
$$;
revoke all on function public.owner_impact(uuid) from public, anon, authenticated;
grant execute on function public.owner_impact(uuid) to service_role;

-- Untuk "lupa kata sandi": apakah email ini owner aktif atau super admin? Hanya server (service_role).
create or replace function public.can_self_reset(p_email text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from auth.users u where lower(u.email) = lower(btrim(p_email)) and (
    exists (select 1 from public.platform_admins a where a.user_id = u.id)
    or exists (select 1 from public.tenant_members m where m.user_id = u.id and m.role = 'owner' and m.is_active)))
$$;
revoke all on function public.can_self_reset(text) from public, anon, authenticated;
grant execute on function public.can_self_reset(text) to service_role;

-- Konten website untuk template (satu panggilan, aman dibaca publik): { texts: {kunci: {bahasa: nilai}}, images: {slot: kunci_r2} }
create or replace function public.site_content_json(p_tenant uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.tenant_is_live(p_tenant) then '{}'::jsonb else jsonb_build_object(
    'texts', coalesce((select jsonb_object_agg(s.key, v.langs) from public.site_texts s
                       cross join lateral (select jsonb_object_agg(x.lang, x.value) as langs from public.site_text_translations x where x.site_text_id = s.id and x.value <> '') v
                       where s.tenant_id = p_tenant and v.langs is not null), '{}'::jsonb),
    'images', coalesce((select jsonb_object_agg(slot, image_key) from public.site_images where tenant_id = p_tenant), '{}'::jsonb)) end
$$;
grant execute on function public.site_content_json(uuid) to anon, authenticated;

-- Simpan hero (teks + foto) dalam satu langkah; berjalan dengan hak pengguna sehingga RLS (hanya owner) tetap berlaku.
-- p = { tenant_id, texts: {"hero.title": {"id": "...", "zh": "..."}}, locks: {"zh": true}, image_key?: "kunci" | "" (hapus) }
create or replace function public.save_site_hero(p jsonb) returns void language plpgsql set search_path = public as $$
declare v_t uuid := (p->>'tenant_id')::uuid; k text; l text; v text; v_id uuid;
begin
  if not public.can_edit_site(v_t) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(coalesce(p->'texts', '{}'::jsonb)) loop
    if k !~ '^hero\.[a-z0-9_]+$' then raise exception 'Kunci tidak valid' using errcode = 'check_violation'; end if;
    insert into public.site_texts (tenant_id, key) values (v_t, k) on conflict (tenant_id, key) do update set key = excluded.key returning id into v_id;
    for l, v in select * from jsonb_each_text(p->'texts'->k) loop
      if length(v) > 400 then raise exception 'Teks terlalu panjang (maks 400 karakter)' using errcode = 'check_violation'; end if;
      if btrim(v) = '' then delete from public.site_text_translations where site_text_id = v_id and lang = l;
      else insert into public.site_text_translations (site_text_id, lang, tenant_id, value, is_locked) values (v_id, l, v_t, btrim(v), coalesce((p->'locks'->>l)::boolean, false))
        on conflict (site_text_id, lang) do update set value = excluded.value, is_locked = excluded.is_locked;
      end if;
    end loop;
  end loop;
  if p ? 'image_key' then
    if coalesce(p->>'image_key', '') = '' then delete from public.site_images where tenant_id = v_t and slot = 'hero';
    else insert into public.site_images (tenant_id, slot, image_key) values (v_t, 'hero', p->>'image_key')
      on conflict (tenant_id, slot) do update set image_key = excluded.image_key; end if;
  end if;
end $$;
