# Tes database (Postgres lokal, bukan Supabase sungguhan)

Memuat migrasi 01–13 ke Postgres 16 kosong dengan stub Supabase (`auth.users`, `auth.uid()`, peran `anon`/`authenticated`/`service_role`), lalu menjalankan skenario.

```bash
createdb dapora_test
psql dapora_test -v ON_ERROR_STOP=1 -q -f supabase/tests/stub-supabase.sql
for f in 01-schema 02-seed-aisin 04-peran 05-tampilan 06-dapora-platform 08-hapus-tenant 09-tagihan 10-tagihan-koreksi 11-tampilan-menu 12-nama-template 13-pesanan-online; do
  psql dapora_test -v ON_ERROR_STOP=1 -q -f supabase/$f.sql
done
psql dapora_test -f supabase/tests/13-pesanan-online.test.sql      # harus berakhir dengan "=== SEMUA TES LULUS ==="
```

`13-pesanan-online.test.sql` memakai data dari `02-seed-aisin.sql` (restoran `aisin`, 14 menu) dan membuat 5 akun uji. Jalankan di database kosong, jangan di produksi.
