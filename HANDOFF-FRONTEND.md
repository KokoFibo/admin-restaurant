# Serah-terima ke frontend

Frontend (`resto-vegetarian1`) memakai **API `/v1`** proyek ini, bukan Supabase langsung. Kontrak lengkap, pemetaan Admin → database → API → tampilan, dan daftar perubahan ada di proyek frontend: `API-CONTRACT.md` dan `CHANGELOG-KONTRAK.md`.

Implementasi di sini: `functions/v1/{site,menu,table,orders,bill-request}.ts` + `server/v1.ts`.
- Tema: preset dan rumus warna turunan ada di `server/v1.ts` (`resolveTheme`), selaras dengan `src/lib/themes.ts` (admin). Frontend hanya memetakan `theme.colors` ke variabel CSS.
- Foto: kunci R2 diubah menjadi URL penuh lewat `PUBLIC_MEDIA_URL`.
- Pesanan: `place_order` menolak dengan `E:closed` saat ditutup; API mengubahnya menjadi HTTP 409.

Hal yang tetap menjadi urusan frontend/DNS: tiap domain restoran (`tenant_domains`) atau `<slug>.<domain-dasar>` harus diarahkan ke proyek Pages frontend (Cloudflare Pages tidak mendukung wildcard custom domain; tambahkan per restoran atau pakai Worker route).
