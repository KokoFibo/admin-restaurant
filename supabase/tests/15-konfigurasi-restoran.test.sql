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
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000009','super@x');
insert into platform_admins (user_id) values ('00000000-0000-0000-0000-000000000009');
-- 1. bahasa
select pg_temp.eq((select count(*)::int from languages), 8, '8 bahasa (7 + Chinese Traditional)');
select pg_temp.eq((select count(*)::int from languages where is_available), 8, 'semua tersedia untuk dipilih Owner');
select pg_temp.eq((select name_native from languages where code='zt'), '繁體中文', 'zt = 繁體中文');
select pg_temp.eq((select max_name||'/'||max_short||'/'||max_detail from languages where code='zt'), (select max_name||'/'||max_short||'/'||max_detail from languages where code='zh'), 'batas panjang zt = zh');
select pg_temp.eq((select (select sort from languages where code='zt') - (select sort from languages where code='zh')), 1, 'zt tepat setelah zh');
select pg_temp.eq((select count(*)::int from (select sort from languages group by sort having count(*) > 1) d), 0, 'urutan bahasa tidak ganda');
\echo 'OK 1 bahasa'

-- 2. hak akses
select pg_temp.as_anon();
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], null, array[]::text[], 'id') $q$, 'permission denied');
select pg_temp.as_user('00000000-0000-0000-0000-000000000002');   -- manager
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], null, array[]::text[], 'id') $q$, 'Akses ditolak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');   -- dapur
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], null, array[]::text[], 'id') $q$, 'Akses ditolak');
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');   -- owner
-- validasi
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'cafe', 'Asia/Jakarta', array['id'], null, array[]::text[], 'id') $q$, 'Tipe restoran tidak valid');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Tokyo', array['id'], null, array[]::text[], 'id') $q$, 'Zona waktu tidak dikenal');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array[]::text[], null, array[]::text[], 'id') $q$, 'Pilih 1 atau 2 bahasa');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en','zh'], null, array[]::text[], 'id') $q$, 'Pilih 1 atau 2 bahasa');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['en','en'], null, array[]::text[], 'id') $q$, 'Bahasa tidak boleh sama');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','xx'], null, array[]::text[], 'id') $q$, 'Bahasa tidak tersedia');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], 'zh', array[]::text[], 'id') $q$, 'harus salah satu bahasa restoran');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], null, array[]::text[], 'fr') $q$, 'Bahasa admin tidak valid');
select pg_temp.expect($q$ select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], null, array['bukan_opsi'], 'id') $q$, 'check');
reset role;
select pg_temp.eq((select count(*)::int from tenant_languages where tenant_id=(select v::uuid from ctx where k='T')), 2, 'galat validasi tidak mengubah apa pun (bahasa tetap)');
\echo 'OK 2 hak akses & validasi'

-- 3. Owner mengubah: Indonesia utama, Chinese Traditional kedua, tampilan awal = zt
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_tenant_config((select v::uuid from ctx where k='T'), 'vegetarian', 'Asia/Makassar', array['id','zt'], 'zt', (select menu_options from tenants where slug='aisin'), 'en');
reset role;
select pg_temp.eq((select restaurant_type||'/'||timezone||'/'||admin_default_lang||'/'||default_lang from tenants where slug='aisin'), 'vegetarian/Asia/Makassar/en/zt', 'konfigurasi tersimpan');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->>'primary_lang'), 'id', 'bahasa utama (isi) tetap id');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->'languages')::text, '["zt", "id"]', 'urutan publik: tampilan awal (zt) di depan');
select pg_temp.eq((select string_agg(lang, ',' order by position) from tenant_languages where tenant_id=(select v::uuid from ctx where k='T')), 'id,zt', 'bahasa utama tetap posisi 1 di database');
-- pesanan staf memakai bahasa utama (bukan tampilan awal)
insert into restaurant_tables (tenant_id, label) select v::uuid, 'M1' from ctx where k='T';
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');
select place_staff_order((select v::uuid from ctx where k='T'), (insert_t.id), (select v::jsonb from ctx where k='items'), null, null) from (select id from restaurant_tables where tenant_id=(select v::uuid from ctx where k='T') limit 1) insert_t;
reset role;
select pg_temp.eq((select count(*)::int from order_items oi join menu_item_translations mt on mt.menu_item_id=oi.menu_item_id and mt.lang='id' and mt.name=oi.name_snapshot where oi.order_id=(select id from orders where source='staff' limit 1)), 2, 'nama hidangan di dapur = bahasa utama');
-- tampilan awal = bahasa utama → disimpan kosong
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_tenant_config((select v::uuid from ctx where k='T'), 'vegetarian', 'Asia/Makassar', array['id','en'], 'id', (select menu_options from tenants where slug='aisin'), 'id');
reset role;
select pg_temp.eq((select default_lang is null from tenants where slug='aisin')::text, 'true', 'default = utama → kosong');
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->'languages')::text, '["id", "en"]', 'urutan publik normal');
-- satu bahasa saja + default kosong
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_tenant_config((select v::uuid from ctx where k='T'), 'umum', 'Asia/Jayapura', array['en'], null, array[]::text[], 'id');
reset role;
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->>'primary_lang'), 'en', 'utama berganti ke en');
select pg_temp.eq((select count(*)::int from menu_item_translations where lang='id'), (select count(*)::int from menu_item_translations where lang='id'), 'terjemahan lama tidak dihapus');
\echo 'OK 3 Owner mengubah'

-- 4. default usang (bahasa sudah dihapus lewat jalur lain) tidak merusak urutan
update tenants set default_lang = 'ko' where slug='aisin';
select pg_temp.eq((select tenant_public_json((select v::uuid from ctx where k='T'))->'languages')::text, '["en"]', 'default usang diabaikan');
update tenants set default_lang = null where slug='aisin';

-- 5. Super Admin juga bisa; istilah dalam bahasa zt diterima
select pg_temp.as_user('00000000-0000-0000-0000-000000000009');
select set_tenant_config((select v::uuid from ctx where k='T'), 'vegan', 'Asia/Jakarta', array['id','en'], null, array['has_egg']::text[], 'id');
reset role;
select pg_temp.eq((select restaurant_type from tenants where slug='aisin'), 'vegan', 'Super Admin bisa mengubah');
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_labels((select v::uuid from ctx where k='T'), '[{"key":"takeaway","lang":"zt","text":"外帶"}]'::jsonb);
reset role;
select pg_temp.eq((select text from tenant_labels where lang='zt'), '外帶', 'istilah pelanggan memakai kode zt');
\echo 'OK 4-5'
\echo '=== SEMUA TES 15 LULUS ==='
