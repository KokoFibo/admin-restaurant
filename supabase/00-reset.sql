-- 00-reset.sql — HANYA untuk mengosongkan database percobaan.
-- PERINGATAN: menghapus semua tabel aplikasi beserta datanya. Jangan dijalankan di database yang sudah berisi data klien.

drop table if exists
  public.payments, public.bill_tables, public.order_items, public.orders, public.bills, public.order_counters, public.restaurant_tables, public.ai_usage,
  public.site_image_translations, public.site_images, public.site_text_translations, public.site_texts,
  public.menu_item_translations, public.menu_items, public.category_translations, public.categories,
  public.tenant_translations, public.tenant_languages, public.subscriptions, public.tenant_domains,
  public.tenant_members, public.platform_admins, public.plans, public.tenants, public.languages cascade;

-- hapus semua fungsi aplikasi (apa pun tanda tangannya)
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in (
             'is_platform_admin','is_member','is_owner','tenant_is_live','menu_item_is_public','category_is_public','can_manage_folder',
             'resolve_tenant','tenant_public_json','consume_ai','touch_updated_at','check_lang_available','enforce_translation_limits',
             'normalize_menu_options','renormalize_items','master_set_tenant_settings','save_menu_item','save_category',
             'tenant_role','has_role','can_edit_menu','can_reset_password','list_tenant_members','master_link_member','master_remove_member','set_sold_out',
             'can_create_role','resolve_table','place_order','set_order_status','set_order_payment','_next_bill_no','_bill_figures','_open_bill','guard_table_delete','request_bill','list_bills','list_bill_requests','merge_tables','split_orders','set_bill_discount','pay_bill','void_bill','reopen_bill','set_tenant_billing','rotate_table_token','reorder_categories','reorder_menu_items','prevent_slug_change')
  loop execute 'drop function ' || r.sig || ' cascade'; end loop;
end $$;

-- aturan lama pada Storage (versi sebelumnya memakai Supabase Storage; sekarang foto di Cloudflare R2)
drop policy if exists "publik baca foto" on storage.objects;
drop policy if exists "admin unggah foto" on storage.objects;
drop policy if exists "admin ubah foto" on storage.objects;
drop policy if exists "admin hapus foto" on storage.objects;
drop policy if exists "publik baca site-media" on storage.objects;
drop policy if exists "anggota unggah site-media" on storage.objects;
drop policy if exists "anggota ubah site-media" on storage.objects;
drop policy if exists "anggota hapus site-media" on storage.objects;
