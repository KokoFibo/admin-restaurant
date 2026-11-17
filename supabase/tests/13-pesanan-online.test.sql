\set ON_ERROR_STOP on
\set QUIET on
grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to authenticated;
create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), false);
  execute case when u is null then 'set role anon' else 'set role authenticated' end; end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$ begin perform set_config('request.jwt.claim.sub','',false); set role anon; end $$;
-- expect: run sql, require error message containing pat
create or replace function pg_temp.expect(q text, pat text) returns void language plpgsql as $$ begin
  begin execute q; exception when others then
    if sqlerrm like '%' || pat || '%' then return; end if; raise exception 'GALAT TIDAK SESUAI: butuh [%] dapat [%] untuk %', pat, sqlerrm, q; end;
  raise exception 'HARUSNYA GALAT [%]: %', pat, q; end $$;
create or replace function pg_temp.eq(a anyelement, b anyelement, msg text) returns void language plpgsql as $$ begin
  if a is distinct from b then raise exception 'GAGAL %: dapat [%] harusnya [%]', msg, a, b; end if; end $$;

create temp table ctx (k text primary key, v text);
grant all on ctx to public;
reset role;
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-000000000001','owner@x'),('00000000-0000-0000-0000-000000000002','mgr@x'),('00000000-0000-0000-0000-000000000003','cash@x'),
 ('00000000-0000-0000-0000-000000000004','kit@x'),('00000000-0000-0000-0000-000000000005','svc@x');
insert into ctx select 'T', id::text from tenants where slug='aisin';
insert into tenant_members (tenant_id, user_id, role) select v::uuid, u.id, r.role from ctx, (values ('00000000-0000-0000-0000-000000000001'::uuid,'owner'),('00000000-0000-0000-0000-000000000002','manager'),('00000000-0000-0000-0000-000000000003','cashier'),('00000000-0000-0000-0000-000000000004','kitchen'),('00000000-0000-0000-0000-000000000005','service')) r(id, role) join auth.users u on u.id = r.id where k='T';
update tenants set tax_pct = 10, service_pct = 5 where slug='aisin';
insert into ctx select 'items', (select jsonb_agg(jsonb_build_object('id', id, 'qty', 2))::text from (select id from menu_items where tenant_id=(select v::uuid from ctx where k='T') and is_visible and archived_at is null and not is_sold_out order by id limit 2) s);
insert into ctx select 'sub', (select sum(price_idr*2)::text from (select price_idr from menu_items where tenant_id=(select v::uuid from ctx where k='T') and is_visible and archived_at is null and not is_sold_out order by id limit 2) s);

-- 1. mati secara bawaan
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Budi','0812-3456-789','customer','at_pickup','', 'id', repeat('a',32)) $q$, 'E:online_off');
reset role;
-- 2. Owner mengaktifkan; Manager tidak boleh
select pg_temp.as_user('00000000-0000-0000-0000-000000000002');
select pg_temp.expect($q$ select set_online_settings((select v::uuid from ctx where k='T'), true, false, null, 'x') $q$, 'Akses ditolak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select pg_temp.expect($q$ select set_online_settings((select v::uuid from ctx where k='T'), true, true, null, 'x') $q$, 'Unggah gambar QRIS');
select pg_temp.expect($q$ select set_online_settings((select v::uuid from ctx where k='T'), true, false, 'restaurant/tenants/aisin/menu/../x.png', 'x') $q$, 'QRIS tidak valid');
select set_online_settings((select v::uuid from ctx where k='T'), true, true, 'restaurant/tenants/aisin/qris/qris-abc12345.webp', 'Ambil di kasir depan');
reset role;
\echo 'OK 1-2 pengaturan'

-- 3. validasi & pesanan pertama (jalur A)
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), '  ','0812','customer','at_pickup','', 'id', repeat('a',32)) $q$, 'E:name_required');
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Budi','123','customer','at_pickup','', 'id', repeat('a',32)) $q$, 'E:phone_invalid');
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), '[]'::jsonb, 'Budi','0812345678','customer','at_pickup','', 'id', repeat('a',32)) $q$, 'E:empty');
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), '[{"id":"00000000-0000-0000-0000-0000000000ff","qty":1}]'::jsonb, 'Budi','0812345678','customer','at_pickup','', 'id', repeat('a',32)) $q$, 'E:item_unavailable');
insert into pg_temp.ctx select 'A', place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Budi','0812-3456-789','courier','at_pickup','jam 7 malam', 'id', repeat('a',32))::text;
reset role;
select pg_temp.eq((select (v::jsonb->>'status') from ctx where k='A'), 'pending', 'status awal');
-- total = sub + 5% + 10% dari (sub+svc)
select pg_temp.eq((select (v::jsonb->>'total_idr')::int from ctx where k='A'), (select (s + round(s*0.05) + round((s + round(s*0.05))*0.10))::int from (select (select v::numeric from ctx where k='sub') s) z), 'total termasuk layanan+pajak');
select pg_temp.eq((select phone from order_contacts limit 1), '628123456789', 'nomor dinormalisasi');
select pg_temp.eq((select count(*)::int from bills where label like 'Online%'), 0, 'belum ada tagihan sebelum diterima');
\echo 'OK 3 pesanan A'

-- 4. batas laju & tampilan RLS
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Budi','0812-3456-789','customer','at_pickup','', 'id', repeat('b',32)) $q$, 'E:rate_limited');   -- nomor sama
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Ani','0899999999','customer','at_pickup','', 'id', repeat('a',32)) $q$, 'E:rate_limited');   -- perangkat sama
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');   -- dapur
select pg_temp.eq((select count(*)::int from orders where status = 'pending'), 0, 'dapur tidak melihat pending');
select pg_temp.eq((select count(*)::int from order_items), 0, 'dapur tidak melihat isi pending');
select pg_temp.eq((select count(*)::int from order_contacts), 0, 'dapur tidak melihat kontak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');   -- service
select pg_temp.eq((select count(*)::int from orders where status = 'pending'), 0, 'service tidak melihat pending');
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');   -- kasir
select pg_temp.eq((select count(*)::int from orders where status = 'pending'), 1, 'kasir melihat pending');
select pg_temp.eq((select count(*)::int from order_contacts), 1, 'kasir melihat kontak');
select pg_temp.eq((select count(*)::int from order_items), 2, 'kasir melihat isi');
reset role;
\echo 'OK 4 batas laju + RLS'

-- 5. status publik
select pg_temp.as_anon();
select pg_temp.eq((select online_order_status((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='A'))->>'status'), 'pending', 'status publik');
select pg_temp.eq((select (online_order_status((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='A'))::text like '%62812%')::text), 'false', 'status publik tidak memuat nomor WA');
select pg_temp.expect($q$ select online_order_status((select v::uuid from ctx where k='T'), repeat('0',32)) $q$, 'E:invalid_order');
reset role;

-- 6. kasir menerima → dapur → bayar
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.expect($q$ select accept_online_order((select id from orders where source='online' limit 1)) $q$, 'Akses ditolak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
insert into pg_temp.ctx select 'billA', accept_online_order((select id from orders where order_no = (select v::jsonb->>'order_no' from ctx where k='A') and source='online'))::text;
select pg_temp.expect($q$ select accept_online_order((select id from orders where source='online' limit 1)) $q$, 'sudah diproses');
select pg_temp.eq((select label from bills where id = (select v::uuid from ctx where k='billA')), 'Online #0001 · Budi', 'label tagihan');
select pg_temp.eq((list_bills((select v::uuid from ctx where k='T'),'open')->0->'figures'->>'total')::int, (select (v::jsonb->>'total_idr')::int from ctx where k='A'), 'angka tagihan = angka pelanggan');
select pg_temp.eq((select jsonb_array_length(list_bills((select v::uuid from ctx where k='T'),'open'))), 1, 'muncul di tab Tagihan');
select pg_temp.eq((select (list_bills((select v::uuid from ctx where k='T'),'open')->0->'orders'->0->>'pickup_by')), 'courier', 'pickup_by di tagihan');
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.eq((select count(*)::int from orders where status = 'new'), 1, 'dapur kini melihat');
select set_order_status((select id from orders where source='online' limit 1), 'preparing');
select set_order_status((select id from orders where source='online' limit 1), 'ready');
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select pay_bill((select v::uuid from ctx where k='billA'), jsonb_build_array(jsonb_build_object('method','cash','amount',(select (v::jsonb->>'total_idr')::int from ctx where k='A'), 'tendered', 50000000)));
select set_order_status((select id from orders where source='online' limit 1), 'done');
reset role;
\echo 'OK 6 jalur A'

-- 7. jalur B (bayar di muka QRIS)
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
insert into pg_temp.ctx select 'B', place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Citra','081111111111','customer','prepay_qris','', 'id', repeat('c',32))::text;
select claim_online_payment((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='B'));
select claim_online_payment((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='B'));   -- idempotent
select pg_temp.eq((select (online_order_status((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='B'))->>'pay_claimed')), 'true', 'klaim bayar');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select pg_temp.expect($q$ select accept_online_order((select id from orders where customer_name='Citra')) $q$, 'dibayar di muka');
select accept_online_prepaid((select id from orders where customer_name='Citra'));
select pg_temp.eq((select status from orders where customer_name='Citra'), 'new', 'prepaid masuk dapur');
select pg_temp.eq((select payment_status from orders where customer_name='Citra'), 'paid', 'prepaid lunas');
select pg_temp.eq((select method from payments p join bills b on b.id=p.bill_id where b.label like '%Citra%'), 'qris', 'metode qris');
select pg_temp.eq((select amount_idr from payments p join bills b on b.id=p.bill_id where b.label like '%Citra%'), (select (v::jsonb->>'total_idr')::int from ctx where k='B'), 'nominal = total pelanggan');
select pg_temp.eq((select status from bills where label like '%Citra%'), 'paid', 'tagihan lunas');
reset role;
\echo 'OK 7 jalur B'

-- 8. tolak
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
insert into pg_temp.ctx select 'C', place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Dedi','082222222222','customer','at_pickup','', 'id', repeat('d',32))::text;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select reject_online_order((select id from orders where customer_name='Dedi'), 'Stok habis');
select pg_temp.expect($q$ select reject_online_order((select id from orders where customer_name='Dedi'), 'x') $q$, 'menunggu konfirmasi');
select pg_temp.expect($q$ select set_order_status((select id from orders where customer_name='Dedi'), 'new') $q$, 'Terima / Tolak');
select pg_temp.as_anon();
select pg_temp.eq((select online_order_status((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='C'))->>'reject_reason'), 'Stok habis', 'alasan tolak tampil');
reset role;
\echo 'OK 8 tolak'

-- 9. kedaluwarsa 15 menit
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
insert into pg_temp.ctx select 'D', place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Eka','083333333333','customer','at_pickup','', 'id', repeat('e',32))::text;
reset role;
update orders set created_at = now() - interval '20 minutes' where customer_name='Eka';
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select pg_temp.expect($q$ select accept_online_order((select id from orders where customer_name='Eka')) $q$, 'kedaluwarsa');
select pg_temp.eq(sweep_online_orders((select v::uuid from ctx where k='T')), 1, 'sapuan staf mengedaluwarsakan 1 pesanan');
select pg_temp.eq((select status from orders where customer_name='Eka'), 'expired', 'status expired');
reset role;
-- sapuan oleh halaman pelanggan (tanpa staf)
update orders set created_at = now() - interval '2 minutes' where customer_name='Eka'; update orders set status='pending', created_at = now() - interval '16 minutes' where customer_name='Eka';
select pg_temp.as_anon();
select pg_temp.eq((select online_order_status((select v::uuid from ctx where k='T'), (select v::jsonb->>'token' from ctx where k='D'))->>'status'), 'expired', 'pelanggan memuat → expired');
reset role;
\echo 'OK 9 kedaluwarsa'

-- 10. batalkan pesanan online yang sudah diterima → tagihan di-void
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
insert into pg_temp.ctx select 'E', place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Fani','084444444444','customer','at_pickup','', 'id', repeat('f',32))::text;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select accept_online_order((select id from orders where customer_name='Fani'));
select set_order_status((select id from orders where customer_name='Fani'), 'cancelled');
select pg_temp.eq((select status from bills where label like '%Fani%'), 'void', 'tagihan di-void saat batal');
reset role;
\echo 'OK 10 batal → void'

-- 11. pajak berubah antara pesan dan konfirmasi (jalur B)
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
insert into pg_temp.ctx select 'F', place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Gita','085555555555','customer','prepay_qris','', 'id', repeat('1',32))::text;
reset role;
update tenants set tax_pct = 11 where slug='aisin';
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select pg_temp.expect($q$ select accept_online_prepaid((select id from orders where customer_name='Gita')) $q$, 'berubah sejak pesanan dibuat');
reset role; update tenants set tax_pct = 10 where slug='aisin';
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select accept_online_prepaid((select id from orders where customer_name='Gita'));
reset role;
\echo 'OK 11 pajak berubah'

-- 12. batas pending: 3 per perangkat, 30 per restoran, tutup sementara
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'H1','086666666601','customer','at_pickup','', 'id', repeat('2',32));
reset role; update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'H2','086666666602','customer','at_pickup','', 'id', repeat('2',32));
reset role; update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'H3','086666666603','customer','at_pickup','', 'id', repeat('2',32));
reset role; update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'H4','086666666604','customer','at_pickup','', 'id', repeat('2',32)) $q$, 'E:pending_full');
reset role;
-- 30 per restoran: isi sampai 30 pending (sisa dari perangkat lain) lalu coba perangkat baru
insert into orders (tenant_id, table_label, order_no, mode, source, status, total_idr, public_token, pickup_by, pay_plan, client_id)
  select (select v::uuid from ctx where k='T'), 'Online', 'X' || g, 'takeaway', 'online', 'pending', 1, md5(g::text), 'customer', 'at_pickup', md5('c' || g) from generate_series(1, 30) g;
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Baru','087777777777','customer','at_pickup','', 'id', repeat('9',32)) $q$, 'E:pending_full');
reset role;
delete from orders where order_no like 'X%';
update orders set status='rejected' where status='pending';
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
update tenants set orders_paused = true where slug='aisin';
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Baru','087777777777','customer','at_pickup','', 'id', repeat('9',32)) $q$, 'E:closed');
reset role; update tenants set orders_paused = false where slug='aisin';
\echo 'OK 12 batas & tutup sementara'

-- 13. nomor WA dihapus setelah 30 hari
update order_contacts set created_at = now() - interval '31 days' where phone = '628123456789';
select pg_temp.as_anon();
select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Zed','088888888888','customer','at_pickup','', 'id', repeat('8',32));
reset role;
select pg_temp.eq((select count(*)::int from order_contacts where phone = '628123456789'), 0, 'kontak >30 hari dihapus');
select pg_temp.eq((select count(*)::int from orders where customer_name = 'Budi'), 1, 'pesanan tetap ada, hanya kontak yang dihapus');
\echo 'OK 13 retensi nomor'

-- 14. regresi: pesanan meja (QR) tetap jalan, tagihan/gabung tidak terganggu
insert into restaurant_tables (tenant_id, label) select v::uuid, 'M1' from ctx where k='T';
insert into ctx select 'tok', token from restaurant_tables where label='M1';
select pg_temp.as_anon();
select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tok'), (select v::jsonb from ctx where k='items'), 'Meja', '', 'id', repeat('7',32));
reset role;
select pg_temp.eq((select source from orders where table_label='M1'), 'dine_in', 'pesanan meja tetap dine_in');
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.eq((select count(*)::int from orders where table_label='M1'), 1, 'dapur melihat pesanan meja');
reset role;
\echo 'OK 14 regresi dine-in'

-- 15. jalur B ditolak bila dimatikan
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_online_settings((select v::uuid from ctx where k='T'), true, false, null, null);
reset role;
update orders set created_at = created_at - interval '2 minutes'; update order_contacts set created_at = created_at - interval '2 minutes';
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_online_order((select v::uuid from ctx where k='T'), (select v::jsonb from ctx where k='items'), 'Q','089999999999','customer','prepay_qris','', 'id', repeat('6',32)) $q$, 'E:prepay_off');
reset role;
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->>'online_enabled'), 'true', 'online_enabled di JSON publik');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->>'online_prepay'), 'false', 'online_prepay mati');
\echo 'OK 15 prepay mati + JSON publik'
\echo '=== SEMUA TES LULUS ==='
