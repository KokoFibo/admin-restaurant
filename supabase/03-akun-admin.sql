-- 03-akun-admin.sql — menjadikan akunmu MASTER (Super Admin) dan menghubungkan pemilik pertama restoran Aisin.
-- Buat dulu akunnya di Authentication > Users > Add user (centang Auto Confirm). Ganti email, lalu Run.
-- Akun owner/manager/cashier/kitchen/service berikutnya dibuat dari aplikasi admin (admin.<domain>) (tab Akun) oleh master.

-- (a) Super Admin (kamu): boleh melihat dan mengelola SEMUA restoran dan semua akun
insert into public.platform_admins (user_id)
select id from auth.users where email = 'kokonacci@gmail.com'
on conflict do nothing;

-- (b) Owner restoran "aisin" (opsional jika memakai tab Akun)
insert into public.tenant_members (tenant_id, user_id, role)
select t.id, u.id, 'owner'
from public.tenants t, auth.users u
where t.slug = 'aisin' and u.email = 'owner@gmail.com'
on conflict (tenant_id, user_id) do update set role = excluded.role;


-- test