-- 11-tampilan-menu.sql — pilihan Owner: menu DENGAN FOTO atau TEKS SAJA. Jalankan setelah 06 (dan 09/10 bila dipakai). Aman diulang.
-- Foto yang sudah diunggah TIDAK dihapus saat berpindah mode (bisa kembali kapan saja).
alter table public.tenants add column if not exists menu_display text not null default 'photo' check (menu_display in ('photo', 'text'));

-- Tambahkan menu_display ke JSON publik restoran (menyambung ke versi 06: base + template_id).
create or replace function public.tenant_public_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select public.tenant_public_json_base(p_id) || (select jsonb_build_object('template_id', t.template_id, 'menu_display', t.menu_display) from public.tenants t where t.id = p_id)
$$;

create or replace function public.set_menu_display(p_tenant uuid, p_mode text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(p_tenant, array['owner']) then raise exception 'Akses ditolak' using errcode = '42501'; end if;
  if p_mode not in ('photo', 'text') then raise exception 'Mode tidak valid' using errcode = 'check_violation'; end if;
  update public.tenants set menu_display = p_mode where id = p_tenant;
end $$;
revoke execute on function public.set_menu_display(uuid, text) from public, anon;
grant execute on function public.set_menu_display(uuid, text) to authenticated;
