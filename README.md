# Backend admin — admin.kokofibo.com (nanti admin.dapora.com)

Aplikasi admin (Vue 3 + Vite) terpisah dari website. **Satu alamat untuk semua restoran**: owner dan staf membuka `admin.kokofibo.com`, login, lalu sistem membaca restoran dan role dari akun (tabel `tenant_members`). Nama host tidak dipakai untuk menentukan restoran.

- **Database & login**: Supabase (`supabase/*.sql`, urutan 00 → 01 → 02 → 03 → 04 → **05**).
- **Foto**: Cloudflare R2 lewat `/api/upload` (menu 4:3 ≤60 KB; hero 4:5 ≤140 KB).
- **Terjemahan AI**: `/api/translate` (Gemini). **Akun**: `/api/users`. **Lupa kata sandi**: `/api/forgot`. Semua = Cloudflare Pages Functions (`functions/`), satu domain dengan admin, tanpa CORS.

## Role
| Role | Bisa |
|---|---|
| Super Admin | Semua restoran; buat/reset/nonaktifkan/hapus akun termasuk Owner; pengaturan master |
| Owner | Semua di restorannya + **tab Akun** (buat, reset kata sandi, nonaktifkan, hapus staf) + **tab Tampilan Website** (hero) + profil restoran. Merangkap semua tugas staf (restoran kecil). Satu email boleh jadi owner di banyak restoran |
| Manager | Menu, kategori, meja, pesanan, pembayaran. Tidak ada tab Akun |
| Cashier | Pesanan + catat pembayaran |
| Kitchen | Status pesanan (Baru → Diproses → Siap), tandai menu Habis. Boleh banyak orang |
| Service | Pesanan Siap → Selesai. Boleh banyak orang |

Staf hanya boleh di **satu** restoran. Akun nonaktif tidak bisa login dan akses datanya langsung tertutup. Hapus akun = permanen (riwayat pesanan tetap); ditolak bila dia owner aktif satu-satunya sebuah restoran. Semua aturan ada di database (`04-peran.sql`), bukan hanya di tampilan.

## Pasang
1. Supabase SQL Editor: jalankan `00` → `01` → `02` → `03` → `04` → `05` (04 dan 05 aman diulang). Restoran dan owner baru dibuat manual lewat SQL dulu (nanti lewat sistem SaaS).
2. `cp .env.example .env`, isi. `PUBLIC_*` ikut ke browser; sisanya rahasia server.
3. Cloudflare Pages: build `npm run build`, output `dist`; isi variabel di *Settings → Variables and Secrets* (rahasia sebagai **Secret**). *Custom domain*: `admin.kokofibo.com`.
4. Supabase → Authentication → URL Configuration: tambahkan `https://admin.kokofibo.com` (Site URL & Redirect URLs).
5. **Lupa kata sandi (khusus Owner)** butuh SMTP: Supabase → Authentication → SMTP Settings (mis. Resend). Tanpa SMTP, email bawaan Supabase sangat dibatasi.
6. Alamat website tiap restoran: domain sendiri → isi `tenant_domains` (status `active`); tanpa domain → otomatis `https://<slug>.<PUBLIC_BASE_DOMAIN>`. Slug `admin`, `www`, `api` dilarang. Wildcard DNS `*.kokofibo.com` + frontend yang mengenali slug = urusan proyek frontend (lihat `HANDOFF-FRONTEND.md`).
7. Pindah ke dapora.com: ganti `PUBLIC_BASE_DOMAIN`, pasang `admin.dapora.com`, daftarkan di Redirect URLs. Semua pengguna login ulang (sesi per-origin).

## Lokal
`npm install && npm run pages:dev` (UI + Functions; rahasia di `.dev.vars`). `npm run dev` hanya UI.

## Tampilan website (tahap 1)
| Fitur | Super Admin | Owner | Manager |
|---|---|---|---|
| Skema warna (7 pilihan) | ✔ | ✔ | — |
| Warna sendiri: utama, aksen, dasar | ✔ (hex bebas) | ✔ (dasar dari 6 pilihan, kontras dicek) | — |
| Latar gelap, zona waktu restoran | ✔ | — | — |
| Hero (foto & teks) | ✔ | ✔ | — |
| Banner info/promo/libur (maks 3 aktif) | ✔ | ✔ | ✔ |
| Tutup sementara (matikan pemesanan QR) | ✔ | ✔ | ✔ |
| Hidangan unggulan (★, maks 6) | ✔ | ✔ | ✔ |

Aturan (peran, kontras warna WCAG 4,5:1, batas 3 banner, batas 6 unggulan, pemesanan ditolak saat ditutup) dijaga **database** (`05-tampilan.sql`), bukan hanya tampilan admin. Banner jenis Libur bisa menutup pemesanan selama periodenya; `place_order` menolak dengan kode `E:closed`.
