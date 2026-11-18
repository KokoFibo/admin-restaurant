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


reset role;
with i as (insert into restaurant_tables (tenant_id, label, sort) select v::uuid, 'M1', 1 from ctx where k='T' returning id) insert into ctx select 'tbl', id::text from i;
with i as (insert into restaurant_tables (tenant_id, label, sort) select v::uuid, 'M2', 2 from ctx where k='T' returning id) insert into ctx select 'tbl2', id::text from i;
insert into ctx select 'tok1', token from restaurant_tables where label='M1';

-- 1. nama istilah
select pg_temp.as_user('00000000-0000-0000-0000-000000000002');
select pg_temp.expect($q$ select set_labels((select v::uuid from ctx where k='T'), '[{"key":"takeaway","lang":"id","text":"Bungkus"}]'::jsonb) $q$, 'Akses ditolak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select pg_temp.expect($q$ select set_labels((select v::uuid from ctx where k='T'), '[{"key":"hack","lang":"id","text":"x"}]'::jsonb) $q$, 'check');
select pg_temp.expect($q$ select set_labels((select v::uuid from ctx where k='T'), '[{"key":"accept","lang":"id","text":"x"}]'::jsonb) $q$, 'check');      -- teks staf harus lang '*'
select pg_temp.expect($q$ select set_labels((select v::uuid from ctx where k='T'), '[{"key":"takeaway","lang":"*","text":"x"}]'::jsonb) $q$, 'check');    -- teks pelanggan tidak boleh '*'
select set_labels((select v::uuid from ctx where k='T'), jsonb_build_array(jsonb_build_object('key','takeaway','lang','id','text',repeat('x',41))));   -- dipotong 40, bukan galat
reset role;
select pg_temp.eq((select char_length(text) from tenant_labels where key='takeaway'), 40, 'teks dipotong 40 karakter');
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_labels((select v::uuid from ctx where k='T'), '[{"key":"accept","lang":"*","text":"Setujui"},{"key":"new_order","lang":"*","text":"+ Order staf"},{"key":"send_order","lang":"id","text":"Pesan sekarang"},{"key":"send_order","lang":"en","text":"  "}]'::jsonb);
reset role;
select pg_temp.eq((select count(*)::int from tenant_labels), 3, 'teks kosong tidak disimpan');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->'labels'->'send_order'->>'id'), 'Pesan sekarang', 'istilah pelanggan di JSON publik');
select pg_temp.eq((select (tenant_public_json((select v::uuid from ctx where k='T'))->'labels' ? 'accept')::text), 'false', 'istilah staf TIDAK dibuka ke publik');
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.eq((select count(*)::int from tenant_labels), 3, 'anggota (dapur) bisa membaca istilah untuk UI');
reset role;
\echo 'OK 1 nama istilah'

-- 2. QR Kasir (maks satu)
insert into restaurant_tables (tenant_id, label, sort, kind) select v::uuid, 'Take away', 99, 'counter' from ctx where k='T';
select pg_temp.expect($q$ insert into restaurant_tables (tenant_id, label, kind) select v::uuid, 'Kasir 2', 'counter' from ctx where k='T' $q$, 'duplicate');
insert into ctx select 'tokC', token from restaurant_tables where kind='counter';
select pg_temp.as_anon();
select pg_temp.eq((select resolve_table((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'))->>'kind'), 'counter', 'resolve_table kind=counter');
select pg_temp.eq((select resolve_table((select v::uuid from ctx where k='T'), (select v from ctx where k='tok1'))->>'kind'), 'table', 'resolve_table kind=table');
reset role;

-- 3. pesanan pelanggan lewat QR Kasir
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), (select v::jsonb from ctx where k='items'), '  ', '', 'id', repeat('a',32)) $q$, 'E:name_required');
insert into pg_temp.ctx select 'c1', place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), (select v::jsonb from ctx where k='items'), 'Budi', '', 'id', repeat('a',32))::text;
select pg_temp.expect($q$ select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), (select v::jsonb from ctx where k='items'), 'Budi', '', 'id', repeat('a',32)) $q$, 'E:rate_limited');
insert into pg_temp.ctx select 'c2', place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), (select v::jsonb from ctx where k='items'), 'Ani', '', 'id', repeat('b',32))::text;
reset role;
select pg_temp.eq((select v::jsonb->>'kind' from ctx where k='c1'), 'counter', 'respons kind=counter');
select pg_temp.eq((select count(*)::int from bills where label like 'Take away #%'), 2, 'dua pelanggan kasir = dua tagihan terpisah');
select pg_temp.eq((select label from bills where label like '%Budi') , 'Take away #0001 · Budi', 'label tagihan kasir');
select pg_temp.eq((select count(*)::int from bill_tables bt join bills b on b.id=bt.bill_id where b.label like 'Take away%'), 0, 'tagihan kasir tanpa meja');
select pg_temp.eq((select status from orders where customer_name='Budi'), 'new', 'langsung ke dapur');
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.eq((select count(*)::int from orders where table_label='Take away'), 2, 'dapur melihat pesanan kasir');
reset role;
select pg_temp.as_anon();
select pg_temp.expect($q$ select request_bill((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), repeat('a',32)) $q$, 'E:no_bill');
reset role;
-- tanpa batas 15 pelanggan di kasir
do $$ declare i int; begin
  for i in 1..17 loop
    perform pg_temp.as_anon();
    perform place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), (select v::jsonb from ctx where k='items'), 'P' || i, '', 'id', lpad(i::text, 32, '0'));
    reset role;
  end loop; end $$;
select pg_temp.eq((select count(*)::int from bills where label like 'Take away #%'), 19, '19 tagihan kasir (tanpa batas 15 pelanggan)');
-- kasir membayar tagihan kasir
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select pay_bill((select b.id from bills b where b.label like '%Budi'), jsonb_build_array(jsonb_build_object('method','qris','amount',(select (e->'figures'->>'total')::int from jsonb_array_elements(list_bills((select v::uuid from ctx where k='T'),'open')) e where e->>'label' like '%Budi'))));
select pg_temp.eq((select status from bills where label like '%Budi'), 'paid', 'tagihan kasir bisa dibayar');
reset role;
\echo 'OK 2-3 QR Kasir'

-- 4. regresi meja biasa: pelanggan serempak 1 tagihan
select pg_temp.as_anon();
select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tok1'), (select v::jsonb from ctx where k='items'), 'Meja A', '', 'id', repeat('c',32));
select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tok1'), (select v::jsonb from ctx where k='items'), 'Meja B', '', 'id', repeat('d',32));
reset role;
select pg_temp.eq((select count(distinct bill_id)::int from orders where table_label='M1'), 1, 'meja biasa: pesanan menyatu di satu tagihan');
\echo 'OK 4 regresi meja'

-- 5. pesanan staf
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.expect($q$ select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl'), (select v::jsonb from ctx where k='items'), null, null) $q$, 'Akses ditolak');
select pg_temp.expect($q$ select list_staff_tables((select v::uuid from ctx where k='T')) $q$, 'Akses ditolak');
select pg_temp.expect($q$ select staff_menu((select v::uuid from ctx where k='T')) $q$, 'Akses ditolak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');    -- service
select pg_temp.eq((select count(*)::int from jsonb_array_elements(list_staff_tables((select v::uuid from ctx where k='T'))) e where (e->>'open_bill')::boolean and e->>'label'='M1'), 1, 'M1 bertanda tagihan terbuka');
select pg_temp.eq((select count(*)::int from jsonb_array_elements(list_staff_tables((select v::uuid from ctx where k='T'))) e where not (e->>'open_bill')::boolean and e->>'label'='M2'), 1, 'M2 tanpa tagihan');
select pg_temp.eq((select (list_staff_tables((select v::uuid from ctx where k='T'))->-1)->>'kind'), 'counter', 'kasir di urutan terakhir');
select pg_temp.eq((select jsonb_array_length(staff_menu((select v::uuid from ctx where k='T'))->'items')), (select count(*)::int from menu_items where tenant_id=(select v::uuid from ctx where k='T') and is_visible and archived_at is null), 'menu staf = menu tampil');
-- masuk ke tagihan meja yang sudah terbuka
insert into pg_temp.ctx select 'bM1', (select bill_id::text from orders where table_label='M1' limit 1);
select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl'), (select v::jsonb from ctx where k='items'), 'Si Budi', 'tanpa pedas');
select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl'), (select v::jsonb from ctx where k='items'), null, null);   -- tanpa batas 10 dtk
reset role;
select pg_temp.eq((select count(*)::int from orders where bill_id = (select v::uuid from ctx where k='bM1')), 4, 'pesanan staf ikut tagihan terbuka (2 pelanggan + 2 staf)');
select pg_temp.eq((select count(distinct bill_id)::int from orders where table_label='M1'), 1, 'tetap satu tagihan');
select pg_temp.eq((select source from orders where customer_name='Si Budi'), 'staff', 'source=staff');
select pg_temp.eq((select placed_by::text from orders where customer_name='Si Budi'), '00000000-0000-0000-0000-000000000005', 'placed_by = staf');
select pg_temp.eq((select status from orders where customer_name='Si Budi'), 'new', 'langsung ke dapur');
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.eq((select count(*)::int from orders where source='staff'), 2, 'dapur melihat pesanan staf');
reset role;
-- meja tanpa tagihan → tagihan baru dengan meja
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
insert into pg_temp.ctx select 'sM2', place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl2'), (select v::jsonb from ctx where k='items'), null, null)::text;
reset role;
select pg_temp.eq((select count(*)::int from bill_tables bt join bills b on b.id = bt.bill_id where bt.table_label='M2' and b.status='open'), 1, 'meja tanpa tagihan: dibuatkan tagihan baru dengan meja');
-- kasir/take away oleh staf: nama wajib, tagihan sendiri
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');
select pg_temp.expect($q$ select place_staff_order((select v::uuid from ctx where k='T'), (select id from restaurant_tables where kind='counter'), (select v::jsonb from ctx where k='items'), null, null) $q$, 'E:name_required');
select place_staff_order((select v::uuid from ctx where k='T'), (select id from restaurant_tables where kind='counter'), (select v::jsonb from ctx where k='items'), 'Pak Joko', null);
select place_staff_order((select v::uuid from ctx where k='T'), (select id from restaurant_tables where kind='counter'), (select v::jsonb from ctx where k='items'), 'Bu Rina', null);
reset role;
select pg_temp.eq((select count(distinct bill_id)::int from orders where customer_name in ('Pak Joko','Bu Rina')), 2, 'kasir oleh staf: tiap pesanan tagihan sendiri');
-- tetap bisa saat Tutup sementara; pelanggan tidak
update tenants set orders_paused = true where slug='aisin';
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');
select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl'), (select v::jsonb from ctx where k='items'), 'Saat tutup', null);
select pg_temp.as_anon();
select pg_temp.expect($q$ select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tok1'), (select v::jsonb from ctx where k='items'), 'X', '', 'id', repeat('e',32)) $q$, 'E:closed');
reset role; update tenants set orders_paused = false where slug='aisin';
-- validasi: habis/tersembunyi, meja nonaktif
update menu_items set is_sold_out = true where id = (select (v::jsonb->0->>'id')::uuid from ctx where k='items');
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');
select pg_temp.expect($q$ select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl'), (select v::jsonb from ctx where k='items'), null, null) $q$, 'E:item_unavailable');
select pg_temp.expect($q$ select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl'), '[]'::jsonb, null, null) $q$, 'E:empty');
reset role; update menu_items set is_sold_out = false;
update restaurant_tables set is_active = false where label='M2';
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');
select pg_temp.expect($q$ select place_staff_order((select v::uuid from ctx where k='T'), (select v::uuid from ctx where k='tbl2'), (select v::jsonb from ctx where k='items'), null, null) $q$, 'E:invalid_table');
reset role; update restaurant_tables set is_active = true where label='M2';
\echo 'OK 5 pesanan staf'

-- 6. nama istilah mengikuti: QR Kasir berganti nama; salinan lama tidak berubah
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_labels((select v::uuid from ctx where k='T'), '[{"key":"takeaway","lang":"id","text":"Bungkus"},{"key":"add_counter_qr","lang":"*","text":"+ QR Bungkus"}]'::jsonb);
reset role;
select pg_temp.eq((select label from restaurant_tables where kind='counter'), 'Bungkus', 'nama QR kasir mengikuti istilah');
select pg_temp.eq((select count(*)::int from bills where label like 'Take away #%'), 21, 'label tagihan lama TIDAK berubah');
update orders set created_at = created_at - interval '1 minute'; 
select pg_temp.as_anon();
select place_order((select v::uuid from ctx where k='T'), (select v from ctx where k='tokC'), (select v::jsonb from ctx where k='items'), 'Dewi', '', 'id', repeat('f',32));
reset role;
select pg_temp.eq((select count(*)::int from bills where label like 'Bungkus #% · Dewi'), 1, 'pesanan baru memakai nama baru');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->'labels'->'takeaway'->>'id'), 'Bungkus', 'JSON publik: takeaway=Bungkus');
-- bentrok nama dengan meja lain
update restaurant_tables set label = 'Kasir X' where kind='counter';
insert into restaurant_tables (tenant_id, label) select v::uuid, 'Bungkus' from ctx where k='T';
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select pg_temp.expect($q$ select set_labels((select v::uuid from ctx where k='T'), '[{"key":"takeaway","lang":"id","text":"Bungkus"}]'::jsonb) $q$, 'sudah dipakai oleh meja lain');
-- kembalikan ke bawaan
reset role; delete from restaurant_tables where label='Bungkus';
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_labels((select v::uuid from ctx where k='T'), '[]'::jsonb);
reset role;
select pg_temp.eq((select label from restaurant_tables where kind='counter'), 'Take away', 'dikosongkan → kembali ke bawaan');
select pg_temp.eq((select count(*)::int from tenant_labels), 0, 'semua istilah terhapus');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->'labels')::text, '{}', 'labels kosong di JSON publik');
\echo 'OK 6 istilah mengikuti'
\echo '=== SEMUA TES 14 LULUS ==='
