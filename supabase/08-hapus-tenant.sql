-- 08-hapus-tenant.sql — hapus tenant beserta SEMUA data turunannya (aman diulang). Jalankan SETELAH 06-dapora-platform.sql.
-- Dipanggil HANYA oleh /api/purge (service_role) setelah memastikan pemanggilnya Super Admin.
-- Fungsi dicabut dari anon/authenticated, jadi tidak bisa dipanggil lewat API Supabase publik.
-- Seluruh penghapusan berjalan dalam SATU transaksi: gagal di tengah = tidak ada yang terhapus.

-- ---------- akun yang memenuhi syarat ikut terhapus ----------
-- Satu tenant / beberapa tenant : anggota tenant itu yang TIDAK ada di tenant lain yang dipertahankan.
-- SEMUA tenant                  : semua akun, termasuk yang belum terhubung ke restoran mana pun (mis. pendaftar spam).
-- Dalam kedua kasus: Super Admin dan pemanggil (p_keep) tidak pernah ikut.
create or replace function public._purge_users(p_ids uuid[], p_all boolean, p_keep uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(u.id), '{}') from auth.users u
   where not exists (select 1 from public.platform_admins a where a.user_id = u.id)
     and u.id is distinct from p_keep
     and (p_all or (exists (select 1 from public.tenant_members m where m.user_id = u.id and m.tenant_id = any (p_ids))
                    and not exists (select 1 from public.tenant_members o where o.user_id = u.id and o.tenant_id <> all (p_ids))))
$$;

-- ---------- pratinjau: apa saja yang akan hilang ----------
create or replace function public.purge_preview(p_ids uuid[] default null, p_keep uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ids uuid[]; v_users uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_ids from public.tenants where p_ids is null or id = any (p_ids);
  v_users := public._purge_users(v_ids, p_ids is null, p_keep);
  return jsonb_build_object(
    'tenants', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'slug', t.slug,
        'orders',     (select count(*) from public.orders o where o.tenant_id = t.id),
        'menu_items', (select count(*) from public.menu_items m where m.tenant_id = t.id),
        'categories', (select count(*) from public.categories c where c.tenant_id = t.id),
        'tables',     (select count(*) from public.restaurant_tables r where r.tenant_id = t.id),
        'members',    (select count(*) from public.tenant_members x where x.tenant_id = t.id),
        'images',     (select count(*) from public.site_images s where s.tenant_id = t.id) + (select count(*) from public.menu_items m where m.tenant_id = t.id and m.image_key is not null)
      ) order by t.slug) from public.tenants t where t.id = any (v_ids)), '[]'::jsonb),
    'users', coalesce((select jsonb_agg(u.email order by u.email) from auth.users u where u.id = any (v_users)), '[]'::jsonb));
end $$;

-- ---------- hapus ----------
-- p_ids = null berarti SEMUA tenant. p_delete_users = true juga menghapus akun login yang memenuhi syarat di atas.
create or replace function public.purge_tenants(p_ids uuid[] default null, p_delete_users boolean default false, p_keep uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_users uuid[] := '{}'; v_res jsonb;
begin
  select coalesce(array_agg(id), '{}') into v_ids from public.tenants where p_ids is null or id = any (p_ids);
  if cardinality(v_ids) = 0 then return jsonb_build_object('tenants', 0, 'orders', 0, 'menu_items', 0, 'users', 0); end if;

  v_res := jsonb_build_object(
    'tenants',    cardinality(v_ids),
    'orders',     (select count(*) from public.orders where tenant_id = any (v_ids)),
    'menu_items', (select count(*) from public.menu_items where tenant_id = any (v_ids)));

  if p_delete_users then
    v_users := public._purge_users(v_ids, p_ids is null, p_keep);   -- dihitung SEBELUM keanggotaan dihapus
  end if;

  -- dari yang paling "ujung" ke atas (orders/order_items berstatus RESTRICT, jadi harus lebih dulu)
  delete from public.order_items              where tenant_id = any (v_ids);
  delete from public.orders                   where tenant_id = any (v_ids);
  delete from public.category_translations    where tenant_id = any (v_ids);
  delete from public.menu_item_translations   where tenant_id = any (v_ids);
  delete from public.site_text_translations   where tenant_id = any (v_ids);
  delete from public.site_image_translations  where tenant_id = any (v_ids);
  delete from public.site_banner_translations where tenant_id = any (v_ids);
  delete from public.menu_items               where tenant_id = any (v_ids);
  delete from public.categories               where tenant_id = any (v_ids);
  delete from public.tenants                  where id        = any (v_ids);   -- sisanya (domain, anggota, langganan, meja, banner, teks, foto, AI usage, counter) ikut lewat ON DELETE CASCADE

  if cardinality(v_users) > 0 then
    update public.menu_items    set created_by = null where created_by = any (v_users);   -- jejak di tenant yang dipertahankan, agar tidak menghalangi
    update public.site_banners  set created_by = null where created_by = any (v_users);
    update public.orders        set paid_by    = null where paid_by    = any (v_users);
    delete from auth.users where id = any (v_users);
  end if;

  return v_res || jsonb_build_object('users', cardinality(v_users));
end $$;

revoke all on function public._purge_users(uuid[], boolean, uuid)    from public, anon, authenticated;
revoke all on function public.purge_preview(uuid[], uuid)            from public, anon, authenticated;
revoke all on function public.purge_tenants(uuid[], boolean, uuid)   from public, anon, authenticated;
grant execute on function public._purge_users(uuid[], boolean, uuid)  to service_role;
grant execute on function public.purge_preview(uuid[], uuid)          to service_role;
grant execute on function public.purge_tenants(uuid[], boolean, uuid) to service_role;
