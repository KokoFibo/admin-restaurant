# Backend admin — admin.dapora.id

Aplikasi admin (Vue 3 + Vite) terpisah dari website. **Satu alamat untuk semua restoran**: owner dan staf membuka `admin.dapora.id`, login, lalu sistem membaca restoran dan role dari akun (tabel `tenant_members`). Nama host tidak dipakai untuk menentukan restoran.

- **Database & login**: Supabase (`supabase/*.sql`, urutan 00 → 01 → 02 → 03 → 04 → **05**).
- **Foto**: Cloudflare R2 lewat `/api/upload` (menu 4:3 ≤60 KB; hero 4:5 ≤140 KB).
- **Terjemahan AI**: `/api/translate` (Gemini). **Akun**: `/api/users`. **Lupa kata sandi**: `/api/forgot`. **API publik website**: `/v1/*` (lihat bawah). Semua = Cloudflare Pages Functions (`functions/`), satu domain dengan admin, tanpa CORS.

## Role

| Role        | Bisa                                                                                                                                                                                                                                   |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Super Admin | Semua restoran; buat/reset/nonaktifkan/hapus akun termasuk Owner; pengaturan master                                                                                                                                                    |
| Owner       | Semua di restorannya + **tab Akun** (buat, reset kata sandi, nonaktifkan, hapus staf) + **tab Tampilan Website** (hero) + profil restoran. Merangkap semua tugas staf (restoran kecil). Satu email boleh jadi owner di banyak restoran |
| Manager     | Menu, kategori, meja, pesanan, pembayaran. Tidak ada tab Akun                                                                                                                                                                          |
| Cashier     | Pesanan + catat pembayaran                                                                                                                                                                                                             |
| Kitchen     | Status pesanan (Baru → Diproses → Siap), tandai menu Habis. Boleh banyak orang                                                                                                                                                         |
| Service     | Pesanan Siap → Selesai. Boleh banyak orang                                                                                                                                                                                             |

Staf hanya boleh di **satu** restoran. Akun nonaktif tidak bisa login dan akses datanya langsung tertutup. Hapus akun = permanen (riwayat pesanan tetap); ditolak bila dia owner aktif satu-satunya sebuah restoran. Semua aturan ada di database (`04-peran.sql`), bukan hanya di tampilan.

## Pasang

1. Supabase SQL Editor: jalankan `00` → `01` → `02` → `03` → `04` → `05` (04 dan 05 aman diulang). Restoran dan owner baru dibuat manual lewat SQL dulu (nanti lewat sistem SaaS).
2. `cp .env.example .env`, isi. `PUBLIC_*` ikut ke browser; sisanya rahasia server.
3. Cloudflare Pages: build `npm run build`, output `dist`. **`PUBLIC_*` harus sudah terisi SEBELUM build** (Vite menanamkannya ke kode saat build): isi sebagai variabel biasa (Plain text, bukan Secret) untuk lingkungan Production, lalu **deploy ulang** setiap kali nilainya diubah. Bila kosong, halaman login menampilkan peringatan konfigurasi.
   Selain itu: isi variabel di _Settings → Variables and Secrets_ (rahasia sebagai **Secret**). _Custom domain_: `admin.dapora.id`.
4. Supabase → Authentication → URL Configuration: tambahkan `https://admin.dapora.id` (Site URL & Redirect URLs).
5. **Lupa kata sandi (khusus Owner)** butuh SMTP: Supabase → Authentication → SMTP Settings (mis. Resend). Tanpa SMTP, email bawaan Supabase sangat dibatasi.
6. Alamat website tiap restoran: domain sendiri → isi `tenant_domains` (status `active`); tanpa domain → otomatis `https://<slug>.<PUBLIC_BASE_DOMAIN>`. Slug `admin`, `www`, `api` dilarang. Wildcard DNS `*.dapora.id` + frontend yang mengenali slug = urusan proyek frontend (lihat `HANDOFF-FRONTEND.md`).
7. Bila kelak pindah domain: ganti `PUBLIC_BASE_DOMAIN`, pasang `admin.<domain-baru>`, daftarkan di Redirect URLs. Semua pengguna login ulang (sesi per-origin).

## Lokal

`npm install && npm run pages:dev` (UI + Functions; rahasia di `.dev.vars`). `npm run dev` hanya UI.

## Tampilan website (tahap 1)

| Fitur                                  | Super Admin   | Owner                                   | Manager |
| -------------------------------------- | ------------- | --------------------------------------- | ------- |
| Skema warna (7 pilihan)                | ✔             | ✔                                       | —       |
| Warna sendiri: utama, aksen, dasar     | ✔ (hex bebas) | ✔ (dasar dari 6 pilihan, kontras dicek) | —       |
| Latar gelap, zona waktu restoran       | ✔             | —                                       | —       |
| Hero (foto & teks)                     | ✔             | ✔                                       | —       |
| Banner info/promo/libur (maks 3 aktif) | ✔             | ✔                                       | ✔       |
| Tutup sementara (matikan pemesanan QR) | ✔             | ✔                                       | ✔       |
| Hidangan unggulan (★, maks 6)          | ✔             | ✔                                       | ✔       |

Aturan (peran, kontras warna WCAG 4,5:1, batas 3 banner, batas 6 unggulan, pemesanan ditolak saat ditutup) dijaga **database** (`05-tampilan.sql`), bukan hanya tampilan admin. Banner jenis Libur bisa menutup pemesanan selama periodenya; `place_order` menolak dengan kode `E:closed`.

## API publik untuk website (`/v1`)

Website restoran (frontend Astro) hanya berbicara dengan API ini, tidak dengan Supabase. Kontraknya ada di `API-CONTRACT.md` proyek frontend. Kode: `functions/v1/*` dan `server/v1.ts`. Hanya memakai kunci **anon** + RLS/RPC publik (tanpa `service_role`).

| Endpoint                                     | Fungsi                                                                                                                                                                                                                                   |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /v1/site?host=<domain>&slug=<opsional>` | Restoran: profil, bahasa, **tema (warna dihitung di server)**, hero, banner tayang, `orders_open`. Domain dicari di `tenant_domains` (aktif), lalu `<slug>.<PUBLIC_BASE_DOMAIN>`. Slug `admin/www/api` tidak pernah dilayani.            |
| `GET /v1/menu?site=<id>`                     | Kategori + hidangan (hanya yang terlihat, tidak diarsipkan, berurutan), termasuk `featured`.                                                                                                                                             |
| `GET /v1/table?site=<id>&token=<32 hex>`     | Label meja dari QR; 404 bila token salah/nonaktif.                                                                                                                                                                                       |
| `POST /v1/orders`                            | Membuat pesanan lewat `place_order` (harga dihitung ulang di database). Galat: `E:invalid_table` 403 · `E:empty` 400 · `E:rate_limited` 429 · `E:too_many_active` 429 · `E:item_unavailable` 409 · `E:closed` 409 · `E:unavailable` 503. |

**Variabel yang dibaca API saat berjalan** (Cloudflare Pages → Settings → Variables): `PUBLIC_SUPABASE_URL`, `PUBLIC_SUPABASE_ANON_KEY`, `PUBLIC_MEDIA_URL` (untuk membentuk URL foto dari kunci R2), `PUBLIC_BASE_DOMAIN`.

**Alamat API untuk frontend (`API_URL`)**: paling cepat `https://admin.dapora.id` (proyek yang sama). Disarankan menambahkan custom domain `api.dapora.id` ke proyek Pages yang sama lalu memakai `API_URL=https://api.dapora.id` (slug `api` sudah dicadangkan di database). Pesanan sudah dibatasi laju di database (per meja); untuk perlindungan tambahan pasang aturan rate limiting Cloudflare pada `/v1/orders`.

**Diuji** terhadap Postgres sungguhan lewat PostgREST (lapisan HTTP yang dipakai Supabase): 55 pemeriksaan API (bentuk data, tema preset/kustom/gelap, banner dan zona waktu, tutup sementara, banner Libur, hidangan habis, restoran nonaktif, validasi masukan, kode galat) plus rantai penuh frontend → API → database (tema, hero, banner, unggulan, menu, meja, pesanan, `E:closed`).

<!-- ok1 -->

## Hapus data tenant (khusus Super Admin)

Tab **Restoran** → panel **Hapus data tenant** (hanya tampil untuk Super Admin). Dua pilihan: **satu tenant tertentu** atau **semua tenant**.

1. Pilih cakupan → **Lihat yang akan dihapus** (hitungan pesanan, menu, kategori, meja, akun, jumlah foto di R2; tidak mengubah apa pun).
2. Opsional: hapus juga foto di R2, dan hapus juga akun login. Akun Super Admin dan akun yang sedang dipakai tidak pernah ikut terhapus. Akun yang juga anggota restoran lain yang dipertahankan tidak dihapus. Pada "semua tenant", semua akun selain Super Admin ikut (termasuk akun tanpa restoran).
3. Ketik **slug restoran** (satu tenant) atau **HAPUS SEMUA** (semua tenant) untuk mengaktifkan tombol hapus. Teks ini dicek ulang di server.

Pasang: jalankan `supabase/08-hapus-tenant.sql` di SQL Editor (aman diulang). Fungsi `purge_preview` / `purge_tenants` hanya bisa dipanggil `service_role`; `/api/purge` memastikan pemanggil Super Admin (`is_platform_admin`) sebelum memanggilnya. Penghapusan database berjalan dalam **satu transaksi** (gagal = tidak ada yang berubah). Foto R2 dihapus per halaman setelahnya dan hanya di jalur `restaurant/tenants/…` dan `tenants/<uuid>/…`; bila terhenti, tombol **Ulangi hapus foto** tersedia. Butuh `R2_*` dan `SUPABASE_SERVICE_ROLE_KEY` (sudah ada).

<!-- ok -->

## Tagihan meja (gabung meja, pembayaran campuran, pajak/service/diskon)

Pasang: jalankan `supabase/09-tagihan.sql` di SQL Editor **setelah 01–06 dan 08** (aman diulang). Pesanan lama dipindahkan otomatis ke tagihan (yang belum dibayar per meja menjadi tagihan terbuka; sisanya tagihan tertutup).

- **Pelanggan**: pesanan tetap per pelanggan; pesanan susulan dari meja yang sama otomatis masuk tagihan yang sama. Batas: maks 15 pelanggan (perangkat) per meja, 1 pesanan / 10 detik per perangkat. Tombol **Minta bill** memanggil `POST /v1/bill-request`.
- **Kasir / Manager / Owner** — tab **Tagihan**: gabungkan 2+ meja, pisahkan pesanan, diskon manual, bayar sekali dengan beberapa metode (jumlah harus pas, tidak dicicil; tunai menghitung kembalian). **Batalkan pembayaran** dan **Tutup paksa** hanya Manager/Owner.
- **Owner** — tab Restoran → *Pembayaran*: persen biaya layanan dan pajak. Urutan: (subtotal − diskon) + biaya layanan, lalu pajak; disalin ke tagihan saat lunas.
- **Kitchen / Service**: tidak melihat harga/status bayar; Service hanya melihat penanda "Minta bill" (tanpa nominal). Catatan: pembatasan ini ada di tampilan; kolom `orders.total_idr` tetap bisa dibaca anggota restoran lewat API Supabase (RLS tingkat baris, bukan kolom).
- Fungsi `set_order_payment` lama dinonaktifkan (pembayaran hanya lewat `pay_bill`). Pesanan pada tagihan lunas tidak bisa dibatalkan sebelum pembayarannya dibatalkan.
- **Koreksi & undo** (`supabase/10-tagihan-koreksi.sql`, jalankan setelah 09): gabung meja, gabung tagihan, pisah pesanan, dan diskon tercatat di *Riwayat tindakan*. Tombol **Urungkan** mengembalikan tindakan terakhir (berurutan; pesanan yang masuk setelah gabung kembali ke tagihan mejanya). Hanya sebelum dibayar: saat lunas riwayat dikunci, juga setelah "Batalkan pembayaran".

## Tampilan menu: dengan foto / teks saja

Pasang: jalankan `supabase/11-tampilan-menu.sql` (aman diulang). **Owner** memilih di tab Restoran → *Tampilan menu*. Mode **Teks saja**: website menampilkan daftar ringkas (nama, deskripsi, harga, penanda) tanpa foto, dan kolom foto di form menu disembunyikan. Foto yang sudah ada tidak dihapus sehingga bisa kembali ke mode foto kapan saja; foto hero dan banner tidak terpengaruh. Field API baru: `site.menu_display` (`photo` | `text`).

## Nama template

Template `aisin` kini bernama tampilan **Arunika**. Jalankan `supabase/12-nama-template.sql` (aman diulang). Id teknis `aisin` tidak berubah, jadi restoran, tautan pendaftaran, dan frontend lama tetap bekerja.
