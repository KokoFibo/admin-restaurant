# Serah-terima ke frontend (template restoran)

Satu template Astro dipakai semua restoran. Restoran dikenali dari host: domain sendiri (`tenant_domains`) atau `<slug>.<domain-dasar>`; isi (hero, menu, kontak) diambil dari database per restoran.

## Hero dari database
Satu panggilan RPC publik (boleh anon):
```ts
const { data } = await sb.rpc('site_content_json', { p_tenant: tenant.id });
// { texts: { "hero.title": { id: "...", zh: "..." }, ... }, images: { hero: "restaurant/tenants/<slug>/site/hero-xxxx.webp" } }
const tx = (k: string, fallback: string) => data?.texts?.[`hero.${k}`]?.[lang] ?? fallback;   // kosong → teks bawaan template
const heroImg = data?.images?.hero ? `${MEDIA_URL}/${data.images.hero}` : im[2];             // kosong → foto bawaan
```
Kunci: `hero.eyebrow` (label kecil), `hero.title`, `hero.title_em` (kalimat yang ditekankan, `<em>`), `hero.lead`, `hero.chip1`–`hero.chip3`, `hero.cta_order`, `hero.cta_menu`; foto: slot `hero`.

Di `Home.astro`: bungkus tiap teks hero dengan `tx('title', x('Kembali ke kemurnian,','回归本真，'))`, dan `<img src={heroImg}>`. Bila owner tidak mengubah apa pun, tampilan tetap sama seperti sekarang.

## Catatan
- Foto hero disimpan **portrait 4:5** (sesuai `.frame` desktop; `object-fit: cover` menangani rasio lain).
- Kartu di atas foto ("Hidangan andalan — Kuali jamur gunung — Rp 508.000") saat ini tetap statis; kalau foto diganti, keterangan itu bisa tidak cocok. Putuskan: disembunyikan bila hero diganti, atau dibuat bisa diedit juga.
- `/api/orders` (pesanan pelanggan) tetap di frontend. Hapus dari frontend: `src/admin/`, `src/pages/admin/`, `src/pages/api/{upload,translate,users}.ts`, dependensi `sortablejs`, `qrcode`, `aws4fetch`.
- Wildcard DNS `*.kokofibo.com` ke proyek frontend; `resolve_tenant(p_host, p_slug)` sudah ada untuk memetakan host ke restoran.

---
# Tahap 1 — tema, banner, tutup sementara, unggulan (jalankan `05-tampilan.sql`)

## Data
- `resolve_tenant` / `tenant_public_json` kini memuat: `theme` (`giok|teh|samudra|bata|anggur|zaitun|arang|custom`), `theme_custom` (`{primary, accent, bg}`), `theme_dark`, `timezone`.
- `site_content_json(p_tenant)` kini memuat juga: `banners` (yang sedang tayang), `orders_open` (boolean), `featured` (daftar id menu unggulan, urut menu).

## Tema → variabel CSS
Preset (id → primary / secondary / accent / bg / bg2):
giok #2B5B47 #3D735B #C35B3B #FBF8F2 #F4EEE2 · teh #7A4A21 #96623A #A8402A #FBF7F0 #F3EADB · samudra #1F4E6B #2F6F94 #B45F14 #F6F9FB #E8EFF4 · bata #8E2A2A #A84545 #8A6414 #FCF8F4 #F5EBE1 · anggur #5B3A66 #75507F #A5561B #FAF7FA #EFE8F1 · zaitun #4F5D2F #6B7B45 #B0532E #FAF9F3 #EFEDDC · arang #2E3A3F #46565C #C4481F #F8F8F6 #ECECE8.
Untuk `custom`: `secondary = mix(primary, #FFFFFF, 15%)`, `bg2 = mix(bg, primary, 6%)`, teks `#1E2621` (mode gelap `#F2EFE9`). Pemetaan ke template: `--jade`=primary, `--sage`=secondary, `--vm`=accent, `--bg`=bg, `--bg2`=bg2, `--ink`=teks. Teks pada tombol aksen selalu putih (database menjamin kontras ≥ 4,5:1). Ada contoh `derive()` di `src/lib/themes.ts` backend.

## Banner
Tiap banner: `{ id, kind: info|promo|holiday, scope: all|home|order, link_url, blocks_orders, rev, texts: { <lang>: { message, link_label } } }`. Tampilkan sesuai `scope`; `link_url` hanya `https://…` atau `/…`. Pengunjung boleh menutup banner: simpan `id:rev` di localStorage dan tampilkan lagi bila `rev` berubah. Tanggal sudah disaring server menurut `timezone` restoran.

## Tutup sementara
Bila `orders_open = false`: sembunyikan/nonaktifkan tombol pesan dan tampilkan pesan "sedang tutup". Pemesanan juga ditolak server dengan error `E:closed` dari `place_order` — **petakan kode ini di `/api/orders`** (mis. HTTP 409 + pesan tutup) agar pelanggan melihat pesan yang jelas.

## Unggulan
`featured` = id menu (maks 6, urut menu). Beranda menampilkan menu-menu itu; bila kosong, pakai perilaku bawaan sekarang.
