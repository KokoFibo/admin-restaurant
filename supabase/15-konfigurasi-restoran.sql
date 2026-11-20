-- 15-konfigurasi-restoran.sql — KONFIGURASI RESTORAN bisa diubah Owner, semua bahasa yang disiapkan tersedia (+ Chinese Traditional),
-- dan "bahasa tampilan awal" website terpisah dari bahasa utama. Jalankan SETELAH 01…14. Aman diulang (idempotent). Hanya menambah.
--
-- • Bahasa: seluruh isi tabel languages tersedia (id, en, zh, fr, es, ko, ja) + zt = 繁體中文 (Chinese Traditional; kode 2 huruf karena seluruh sistem memakai ^[a-z]{2}$; HTML lang = zh-Hant).
-- • Bahasa UTAMA (tenant_languages.position = 1) = bahasa sumber isi & terjemahan, nama hidangan di dapur, fallback teks yang belum diterjemahkan.
-- • Bahasa TAMPILAN AWAL (tenants.default_lang, kosong = bahasa utama) = bahasa yang dilihat pengunjung di alamat tanpa awalan (mis. "/"). Hanya urutan 'languages' di data publik yang berubah.
-- • set_tenant_config: Owner ATAU Super Admin mengubah tipe, zona waktu, bahasa, tampilan awal, pilihan menu, bahasa admin bawaan dalam satu panggilan.
--   (master_set_tenant_settings tetap ada untuk admin lama; set_tenant_timezone tetap khusus Super Admin.)

-- =====================================================================
-- 1. BAHASA
-- =====================================================================
update public.languages set is_available = true;
do $$ begin
  if not exists (select 1 from public.languages where code = 'zt') then
    update public.languages set sort = sort + 1 where sort > coalesce((select sort from public.languages where code = 'zh'), 0);
    insert into public.languages (code, name_english, name_native, is_available, sort, max_name, max_short, max_detail)
      select 'zt', 'Chinese (Traditional)', '繁體中文', true, coalesce(l.sort, 0) + 1, l.max_name, l.max_short, l.max_detail from public.languages l where l.code = 'zh';
  end if;
end $$;

alter table public.tenants add column if not exists default_lang text check (default_lang is null or default_lang ~ '^[a-z]{2}$');

-- =====================================================================
-- 2. KONFIGURASI (Owner / Super Admin)
-- =====================================================================
-- p_default = bahasa tampilan awal (salah satu dari p_langs; kosong atau sama dengan bahasa utama = bahasa utama).
create or replace function public.set_tenant_config(p_tenant uuid, p_type text, p_tz text, p_langs text[], p_default text, p_options text[], p_admin_lang text default 'id') returns void
language plpgsql security definer set search_path = public as $$
declare i int; v_default text := nullif(btrim(coalesce(p_default, '')), '');
begin
  if not (public.is_platform_admin() or public.has_role(p_tenant, array['owner'])) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_type not in ('vegan', 'vegetarian', 'umum') then raise exception 'Tipe restoran tidak valid' using errcode = 'check_violation'; end if;
  if p_tz not in ('Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura') then raise exception 'Zona waktu tidak dikenal' using errcode = 'check_violation'; end if;
  if p_langs is null or cardinality(p_langs) not between 1 and 2 then raise exception 'Pilih 1 atau 2 bahasa' using errcode = 'check_violation'; end if;
  if cardinality(p_langs) = 2 and p_langs[1] = p_langs[2] then raise exception 'Bahasa tidak boleh sama' using errcode = 'check_violation'; end if;
  if exists (select 1 from unnest(p_langs) x where not exists (select 1 from public.languages l where l.code = x and l.is_available)) then raise exception 'Bahasa tidak tersedia' using errcode = 'check_violation'; end if;
  if v_default is not null and not (v_default = any (p_langs)) then raise exception 'Bahasa tampilan awal harus salah satu bahasa restoran' using errcode = 'check_violation'; end if;
  if v_default = p_langs[1] then v_default := null; end if;       -- sama dengan bahasa utama = bawaan
  if coalesce(p_admin_lang, 'id') not in ('id', 'en') then raise exception 'Bahasa admin tidak valid' using errcode = 'check_violation'; end if;
  update public.tenants set restaurant_type = p_type, timezone = p_tz, menu_options = coalesce(p_options, '{}'), admin_default_lang = coalesce(p_admin_lang, 'id'), default_lang = v_default
   where id = p_tenant;      -- check constraint menolak opsi menu tidak dikenal
  if not found then raise exception 'Restoran tidak ditemukan'; end if;
  delete from public.tenant_languages where tenant_id = p_tenant;
  for i in 1 .. cardinality(p_langs) loop
    insert into public.tenant_languages (tenant_id, lang, position) values (p_tenant, p_langs[i], i);
  end loop;
end $$;

-- =====================================================================
-- 3. DATA PUBLIK: 'languages' diurutkan dengan bahasa tampilan awal di depan; 'primary_lang' = bahasa utama (isi)
-- =====================================================================
create or replace function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select public.tenant_public_json_base(p_id) || jsonb_build_object(
           'template_id', t.template_id, 'menu_display', t.menu_display,
           'online_enabled', t.online_enabled, 'online_prepay', t.online_enabled and t.online_prepay_enabled and t.qris_image_key is not null,
           'qris_image_key', case when t.online_enabled and t.online_prepay_enabled then t.qris_image_key end, 'pickup_note', t.pickup_note,
           'labels', coalesce((select jsonb_object_agg(k.key, k.m) from (select l.key, jsonb_object_agg(l.lang, l.text) as m from public.tenant_labels l where l.tenant_id = p_id and l.lang <> '*' group by l.key) k), '{}'::jsonb),
           'primary_lang', coalesce((select l.lang from public.tenant_languages l where l.tenant_id = p_id and l.position = 1), 'id'),
           'languages', coalesce((select jsonb_agg(l.lang order by (l.lang = t.default_lang) desc, l.position) from public.tenant_languages l where l.tenant_id = p_id), '[]'::jsonb))
    from public.tenants t where t.id = p_id
$$;

-- =====================================================================
-- 4. HAK EKSEKUSI
-- =====================================================================
revoke execute on function public.set_tenant_config(uuid, text, text, text[], text, text[], text) from public, anon;
grant execute on function public.set_tenant_config(uuid, text, text, text[], text, text[], text) to authenticated;
