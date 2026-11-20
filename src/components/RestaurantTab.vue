<script setup lang="ts">
import { reactive, ref, watch } from 'vue';
import { t } from '../lib/i18n';
import { askConfirm, askPrompt } from '../lib/dialog';
import { sb, media } from '../lib/supabase';
import { translate, trErr, uploadImage, deleteImage } from '../lib/api';
import { S, TYPES, TYPE_DEFAULTS, optionMeta, enabled, lim, load, toast, can, siteBase, labels, loadLabels, loadTables } from '../store';
import Field from './Field.vue';
defineProps<{ section: string }>();   // panel mana yang ditampilkan (sub-tab Pengaturan): profil | menu | istilah | pajak | online | konfig
const p = reactive<any>({ phone: '', wa: '', email: '', maps: '', address: '', lunch: '', tea: '', dinner: '', tr: {} }), mst = reactive<any>({ type: 'vegan', alang: 'id', l1: 'id', l2: '', dflt: 'id', tz: 'Asia/Jakarta', opts: {} });
const pMsg = ref(''), mMsg = ref(''), bill = reactive<any>({ tax: 0, service: 0 }), bMsg = ref(''), mode = ref('photo'), dMsg = ref('');
function init() {
  const T = S.T, hr = T.opening_hours || {};
  Object.assign(p, { phone: T.phone || '', wa: T.whatsapp || '', email: T.email || '', maps: T.maps_url || '', address: T.address || '', lunch: hr.lunch || '', tea: hr.tea || '', dinner: hr.dinner || '' });
  p.tr = {}; S.TL.forEach((c: string) => { const r = S.tenTr.find((x: any) => x.lang === c) || {}; p.tr[c] = { brand: r.brand_name || '', tagline: r.tagline || '' }; });
  Object.assign(mst, { tz: T.timezone || 'Asia/Jakarta', type: T.restaurant_type, alang: T.admin_default_lang === 'en' ? 'en' : 'id', l1: S.TL[0], l2: S.TL[1] || '', dflt: T.default_lang && S.TL.includes(T.default_lang) ? T.default_lang : S.TL[0] });
  mst.opts = Object.fromEntries(optionMeta().map(o => [o[0], enabled(o[0])]));
}
watch(() => [S.T, S.tenTr], init, { immediate: true });
watch(() => S.T, T => { bill.tax = Number(T?.tax_pct ?? 0); bill.service = Number(T?.service_pct ?? 0); }, { immediate: true });
watch(() => S.T, T => { mode.value = T?.menu_display === 'text' ? 'text' : 'photo'; }, { immediate: true });
async function saveDisplay() {
  dMsg.value = t('Menyimpan…'); const { error } = await sb.rpc('set_menu_display', { p_tenant: S.tid, p_mode: mode.value });
  if (error) return (dMsg.value = error.message); dMsg.value = ''; toast(t('Tersimpan')); load();
}
async function saveBilling() {
  const tax = Number(bill.tax), svc = Number(bill.service);
  if (!(tax >= 0 && tax <= 100 && svc >= 0 && svc <= 100)) return (bMsg.value = t('Persentase harus antara 0 dan 100.'));
  bMsg.value = t('Menyimpan…'); const { error } = await sb.rpc('set_tenant_billing', { p_tenant: S.tid, p_tax: tax, p_service: svc });
  if (error) return (bMsg.value = error.message); bMsg.value = ''; toast(t('Tersimpan')); load();
}

/* ---------- pesanan online ---------- */
const onl = reactive<any>({ on: false, prepay: false, key: '', note: '' }), oMsg = ref(''), qBusy = ref(false), qNew = ref('');
watch(() => S.T, T => { Object.assign(onl, { on: !!T?.online_enabled, prepay: !!T?.online_prepay_enabled, key: T?.qris_image_key || '', note: T?.pickup_note || '' }); qNew.value = ''; }, { immediate: true });
const orderLink = () => (siteBase() ? siteBase() + '/pesan' : '');
const qrisUrl = () => media(onl.key);
async function copyLink() { try { await navigator.clipboard.writeText(orderLink()); toast(t('Tautan disalin')); } catch { toast(orderLink()); } }
/** Gambar QRIS: dibuat putih-latar, sisi terpanjang maks 800 px, WebP kualitas tinggi supaya tetap terbaca pemindai (maks 150 KB). */
async function pickQris(ev: Event) {
  const f = (ev.target as HTMLInputElement).files?.[0]; (ev.target as HTMLInputElement).value = ''; if (!f) return;
  qBusy.value = true; oMsg.value = '';
  try {
    const img = await new Promise<HTMLImageElement>((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error(t('Berkas bukan gambar yang valid.'))); i.src = URL.createObjectURL(f); });
    const k = Math.min(1, 800 / Math.max(img.naturalWidth, img.naturalHeight)), w = Math.round(img.naturalWidth * k), h = Math.round(img.naturalHeight * k);
    const c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d')!; x.fillStyle = '#fff'; x.fillRect(0, 0, w, h); x.imageSmoothingQuality = 'high'; x.drawImage(img, 0, 0, w, h);
    let blob: Blob | null = null; for (const q of [0.98, 0.92, 0.85, 0.75]) { blob = await new Promise<Blob | null>(r => c.toBlob(r, 'image/webp', q)); if (blob && blob.size <= 150 * 1024) break; }
    if (!blob || blob.size > 150 * 1024) throw new Error(t('Gambar terlalu besar setelah dikompres. Gunakan gambar QRIS yang lebih sederhana.'));
    const old = qNew.value; qNew.value = await uploadImage(blob, 'qris', 'qris'); onl.key = qNew.value; if (old) deleteImage(old);
    oMsg.value = t('Gambar QRIS terunggah. Tekan Simpan untuk menerapkan, lalu uji pindai dari ponsel lain.');
  } catch (e: any) { oMsg.value = e?.message || t('Gagal mengunggah foto'); } finally { qBusy.value = false; }
}
function dropQris() { onl.key = ''; onl.prepay = false; }
async function saveOnline() {
  if (onl.prepay && !onl.key) return (oMsg.value = t('Unggah gambar QRIS dulu untuk mengaktifkan bayar di muka.'));
  oMsg.value = t('Menyimpan…'); const { error } = await sb.rpc('set_online_settings', { p_tenant: S.tid, p_enabled: onl.on, p_prepay: onl.prepay, p_qris_key: onl.key || null, p_note: onl.note.trim() || null });
  if (error) return (oMsg.value = error.message);
  const prev = S.T?.qris_image_key; if (prev && prev !== onl.key) deleteImage(prev);
  oMsg.value = ''; qNew.value = ''; toast(t('Tersimpan')); load();
}

/* ---------- nama istilah & tombol (Owner) ---------- */
// Teks bawaan (placeholder) harus sama dengan bawaan di situs pelanggan dan di tampilan staf.
const PUB_DEF: Record<string, Record<string, string>> = {
  takeaway: { id: 'Take away', en: 'Take away', zh: '外带' },
  online_link: { id: 'Atau pesan online untuk dibawa pulang', en: 'Or order online for takeaway', zh: '或在线订餐外带' },
  send_order: { id: 'Kirim pesanan', en: 'Send order', zh: '提交订单' },
  i_paid: { id: 'Saya sudah bayar', en: 'I have paid', zh: '我已付款' },
};
const pubKeys = () => [['takeaway', t('Nama "take away" (QR kasir, tagihan, kartu pesanan)')], ['online_link', t('Tautan pesan online di halaman Order')], ['send_order', t('Tombol kirim di halaman pesan online')], ['i_paid', t('Tombol "Saya sudah bayar"')]];
const staffKeys = () => [['new_order', t('Tombol pesanan baru oleh staf'), t('+ Pesanan baru')], ['accept', t('Tombol terima pesanan online'), t('Terima')], ['reject', t('Tombol tolak pesanan online'), t('Tolak')], ['payment_received', t('Tombol pembayaran QRIS diterima'), t('Pembayaran diterima')], ['notify_customer', t('Tombol kabari pelanggan'), t('Kabari via WhatsApp')], ['add_counter_qr', t('Tombol tambah QR kasir'), t('+ Tambah QR {0}', labels.value.takeaway?.[S.TL[0]] || 'Take away')]];
const lab = reactive<Record<string, string>>({}), lMsg = ref('');
const pubPh = (k: string, l: string) => PUB_DEF[k]?.[l] || PUB_DEF[k]?.en || '';
function fillLabels() { for (const x of Object.keys(lab)) delete lab[x]; for (const [k, m] of Object.entries(labels.value)) for (const [l, v] of Object.entries(m as any)) lab[`${k}|${l}`] = v as string; }
watch(labels, fillLabels, { immediate: true, deep: true });
async function saveLabels(clear = false) {
  const items: any[] = [];
  if (!clear) {
    for (const [k] of pubKeys()) for (const l of S.TL) { const v = (lab[`${k}|${l}`] || '').trim(); if (v) items.push({ key: k, lang: l, text: v }); }
    for (const [k] of staffKeys()) { const v = (lab[`${k}|*`] || '').trim(); if (v) items.push({ key: k, lang: '*', text: v }); }
  }
  lMsg.value = t('Menyimpan…'); const { error } = await sb.rpc('set_labels', { p_tenant: S.tid, p_items: items });
  if (error) return (lMsg.value = error.message);
  lMsg.value = ''; toast(t('Tersimpan')); await loadLabels(); loadTables();
}
const resetLabels = async () => (await askConfirm(t('Kembalikan semua nama istilah dan tombol ke teks bawaan?'))) && saveLabels(true);
const langs = () => S.langsAll;   // semua bahasa yang disiapkan (tabel languages), termasuk Chinese Traditional
const onL1 = () => { if (mst.l2 === mst.l1) mst.l2 = ''; syncDefault(); };
function syncDefault() { if (!mst.l2 || ![mst.l1, mst.l2].includes(mst.dflt)) mst.dflt = mst.l1; }
watch(() => mst.l2, syncDefault);
async function saveProfile() {
  pMsg.value = t('Menyimpan…'); const hours: any = {}; (['lunch', 'tea', 'dinner'] as const).forEach(k => { const v = p[k].trim(); if (v) hours[k] = v; });
  const up = await sb.from('tenants').update({ phone: p.phone.trim() || null, whatsapp: p.wa.trim() || null, email: p.email.trim() || null, maps_url: p.maps.trim() || null, address: p.address.trim() || null, opening_hours: Object.keys(hours).length ? hours : null }).eq('id', S.tid).select('id');
  if (up.error || !up.data?.length) return (pMsg.value = t('Gagal menyimpan profil (hanya owner dan Super Admin yang boleh mengubahnya).'));
  const rows = S.TL.map((c: string) => ({ tenant_id: S.tid, lang: c, brand_name: p.tr[c].brand.trim(), tagline: p.tr[c].tagline.trim() || null })).filter((r: any) => r.brand_name);
  const tr = await sb.from('tenant_translations').upsert(rows, { onConflict: 'tenant_id,lang' });
  if (tr.error) return (pMsg.value = t('Gagal menyimpan nama: {0}', tr.error.message));
  pMsg.value = ''; toast(t('Tersimpan')); load();
}
async function trTagline() {
  const a = S.TL[0], b = S.TL[1], v = p.tr[a].tagline.trim(); if (!v) return; pMsg.value = t('Menerjemahkan…');
  try { p.tr[b].tagline = ((await translate(a, b, { tagline: v })).fields.tagline || '').slice(0, 160); pMsg.value = t('Periksa terjemahan, lalu simpan.'); } catch (e: any) { pMsg.value = trErr(e); }
}
const onType = () => { const d = TYPE_DEFAULTS[mst.type] || []; Object.keys(mst.opts).forEach(k => (mst.opts[k] = d.includes(k))); };
async function saveConfig() {
  if (mst.l2 && mst.l1 === mst.l2) return (mMsg.value = t('Bahasa kedua tidak boleh sama dengan bahasa utama.'));
  if (!(await askConfirm(t('Simpan konfigurasi restoran? Data menu yang memakai pilihan yang dimatikan akan dikosongkan.'), { title: t('Konfigurasi Restoran') }))) return;
  mMsg.value = t('Menyimpan…');
  const { error } = await sb.rpc('set_tenant_config', { p_tenant: S.tid, p_type: mst.type, p_tz: mst.tz, p_langs: mst.l2 ? [mst.l1, mst.l2] : [mst.l1], p_default: mst.l2 ? mst.dflt : null, p_options: Object.keys(mst.opts).filter(k => mst.opts[k]), p_admin_lang: mst.alang });
  if (error) return (mMsg.value = error.message);
  mMsg.value = ''; toast(t('Tersimpan')); load(true);
}
</script>
<template>
  <div>
    <template v-if="can.resto()">
    <form v-if="section === 'profil'" class="panel" @submit.prevent="saveProfile"><h3>{{ t('Profil Restoran') }}</h3>
      <div class="grid2"><label>{{ t('Telepon') }}<input v-model="p.phone" /></label><label>WhatsApp<input v-model="p.wa" /></label><label>Email<input v-model="p.email" /></label>
        <label>{{ t('Peta: tautan Google Maps') }}<input v-model="p.maps" placeholder="https://maps.app.goo.gl/…" /></label></div>
      <Field v-model="p.address" :label="t('Alamat (diisi satu kali, tidak diterjemahkan)')" :max="300" :rows="2" />
      <div class="grid2"><label>{{ t('Jam makan siang') }}<input v-model="p.lunch" placeholder="11:30-14:30" /></label><label>{{ t('Jam teh sore') }}<input v-model="p.tea" placeholder="14:30-17:00" /></label><label>{{ t('Jam makan malam') }}<input v-model="p.dinner" placeholder="17:30-21:30" /></label></div>
      <fieldset v-for="(c, i) in S.TL" :key="c"><legend>{{ lim(c).name_native }} {{ i === 0 ? t('— bahasa utama') : '' }}</legend>
        <Field v-model="p.tr[c].brand" :label="t('Nama brand')" :max="80" /><Field v-model="p.tr[c].tagline" :label="t('Slogan')" :max="160" /></fieldset>
      <div v-if="S.TL.length > 1" class="row"><button type="button" class="btn ghost" @click="trTagline">{{ t('Terjemahkan slogan') }}</button></div>
      <p class="err">{{ pMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan profil') }}</button></div></form>
    <form v-if="section === 'menu'" class="panel" @submit.prevent="saveDisplay"><h3>{{ t('Tampilan Menu') }}</h3>
      <label class="opt"><input v-model="mode" type="radio" value="photo" /><span>{{ t('Dengan foto (kartu)') }}</span></label>
      <label class="opt"><input v-model="mode" type="radio" value="text" /><span>{{ t('Teks saja (daftar ringkas: nama, deskripsi, harga)') }}</span></label>
      <p class="hint">{{ t('Foto yang sudah diunggah tidak dihapus saat Anda berpindah mode, dan bisa dipakai lagi kapan saja. Foto hero dan banner tidak terpengaruh.') }}</p>
      <p class="err">{{ dMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan tampilan menu') }}</button></div></form>
    <form v-if="section === 'pajak'" class="panel" @submit.prevent="saveBilling"><h3>{{ t('Pajak & Biaya Layanan') }}</h3>
      <div class="grid2"><label>{{ t('Biaya layanan (%)') }}<input v-model="bill.service" type="number" min="0" max="100" step="0.01" /></label><label>{{ t('Pajak (%)') }}<input v-model="bill.tax" type="number" min="0" max="100" step="0.01" /></label></div>
      <p class="hint">{{ t('Dihitung di tagihan: (subtotal − diskon) + biaya layanan, lalu pajak atas jumlah itu. Isi 0 bila tidak dipakai. Harga menu dianggap belum termasuk keduanya. Tagihan yang sudah lunas tidak berubah.') }}</p>
      <p class="err">{{ bMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan pembayaran') }}</button></div></form>
    <form v-if="section === 'online'" class="panel" @submit.prevent="saveOnline"><h3>{{ t('Pesanan Online') }}</h3>
      <label class="swrow"><span>{{ t('Aktifkan pesanan online') }}</span><span class="switch"><input v-model="onl.on" type="checkbox" role="switch" /><i aria-hidden="true"></i></span></label>
      <p class="hint">{{ t('Pelanggan memesan lewat tautan di bawah (tanpa memindai QR meja). Pesanan masuk ke tab Pesanan sebagai "Menunggu konfirmasi" dan baru masuk dapur setelah Anda menerimanya. Tombol "Tutup sementara" juga menutup pesanan online.') }}</p>
      <div v-if="orderLink()" class="copyrow"><input :value="orderLink()" readonly @focus="($event.target as HTMLInputElement).select()" /><button type="button" class="btn ghost" @click="copyLink">{{ t('Salin tautan') }}</button></div>
      <p v-if="orderLink() && !onl.on" class="hint">{{ t('Tautan ini baru berfungsi setelah pesanan online diaktifkan dan disimpan.') }}</p>
      <label>{{ t('Petunjuk pengambilan (opsional, tampil di halaman pesanan pelanggan)') }}<textarea v-model="onl.note" rows="2" maxlength="300" :placeholder="t('Mis. Ambil di kasir depan. Sebutkan nomor pesanan.')" /></label>
      <fieldset><legend>{{ t('Bayar di muka via QRIS (opsional)') }}</legend>
        <p class="hint">{{ t('Tanpa payment gateway. Pelanggan membayar ke QRIS statis restoran lalu menekan "Saya sudah bayar"; staf memeriksa di aplikasi merchant sendiri dan menekan "Pembayaran diterima". Nominal yang harus dibayar sudah termasuk pajak dan biaya layanan. Bila nominal yang masuk tidak sesuai, tolak pesanan dan kembalikan dana di luar sistem.') }}</p>
        <img v-if="qrisUrl()" class="qrisprev" :src="qrisUrl()!" :alt="t('Gambar QRIS')" />
        <div class="row" style="gap:.5rem;flex-wrap:wrap"><label class="btn ghost" style="cursor:pointer">{{ onl.key ? t('Ganti gambar QRIS') : t('Unggah gambar QRIS') }}<input type="file" accept="image/*" hidden :disabled="qBusy" @change="pickQris" /></label>
          <button v-if="onl.key" type="button" class="btn ghost danger" @click="dropQris">{{ t('Hapus gambar QRIS') }}</button></div>
        <label class="swrow" :class="{ dis: !onl.key }"><span>{{ t('Izinkan pelanggan memilih bayar di muka (QRIS)') }}</span><span class="switch"><input v-model="onl.prepay" type="checkbox" role="switch" :disabled="!onl.key" /><i aria-hidden="true"></i></span></label>
        <p class="hint">{{ t('Gunakan tangkapan layar atau berkas QRIS yang jelas dan tidak buram. Setelah menyimpan, coba pindai dari halaman pesan dengan ponsel lain sebelum dipakai pelanggan.') }}</p></fieldset>
      <p class="err">{{ oMsg }}</p><div class="row"><button class="btn vm" type="submit" :disabled="qBusy">{{ t('Simpan pesanan online') }}</button></div></form>
    <form v-if="section === 'istilah'" class="panel" @submit.prevent="saveLabels(false)"><h3>{{ t('Kustomisasi Istilah & Tombol') }}</h3>
      <p class="hint">{{ t('Ganti kata atau nama tombol sesuai gaya restoran Anda, misalnya "Take away" menjadi "Bungkus". Kolom kosong memakai teks bawaan (ditampilkan samar). Maksimal 40 karakter. Tagihan dan pesanan yang sudah tersimpan tidak berubah; nama baru dipakai untuk yang berikutnya.') }}</p>
      <fieldset><legend>{{ t('Tampil ke pelanggan (per bahasa)') }}</legend>
        <div v-for="[k, title] in pubKeys()" :key="k" class="labgrp"><b>{{ title }}</b>
          <label v-for="l in S.TL" :key="l" class="labrow"><span>{{ lim(l).name_native }}</span><input v-model="lab[`${k}|${l}`]" maxlength="40" :placeholder="pubPh(k, l)" /></label></div></fieldset>
      <fieldset><legend>{{ t('Tampil ke staf (admin)') }}</legend>
        <label v-for="[k, title, def] in staffKeys()" :key="k" class="labrow"><span>{{ title }}</span><input v-model="lab[`${k}|*`]" maxlength="40" :placeholder="def" /></label></fieldset>
      <p class="err">{{ lMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan nama istilah') }}</button><button class="btn ghost" type="button" @click="resetLabels">{{ t('Kembalikan ke bawaan') }}</button></div></form>
    <form v-if="section === 'konfig'" class="panel" @submit.prevent="saveConfig"><h3>{{ t('Konfigurasi Restoran') }}</h3>
      <div class="grid2">
        <label>{{ t('Tipe restoran') }}<select v-model="mst.type" @change="onType"><option v-for="(v, k) in TYPES" :key="k" :value="k">{{ v }}</option></select></label>
        <label>{{ t('Zona waktu restoran') }}<select v-model="mst.tz"><option value="Asia/Jakarta">WIB (Jakarta)</option><option value="Asia/Makassar">WITA (Makassar)</option><option value="Asia/Jayapura">WIT (Jayapura)</option></select></label>
        <label>{{ t('Bahasa utama') }}<select v-model="mst.l1" @change="onL1"><option v-for="l in langs()" :key="l.code" :value="l.code">{{ l.name_native }}</option></select></label>
        <label>{{ t('Bahasa kedua (opsional)') }}<select v-model="mst.l2"><option value="">{{ t('— tidak ada —') }}</option><option v-for="l in langs().filter((x: any) => x.code !== mst.l1)" :key="l.code" :value="l.code">{{ l.name_native }}</option></select></label></div>
      <p class="hint">{{ t('Bahasa utama = bahasa sumber isi dan terjemahan (dan nama hidangan di dapur). Maksimal 2 bahasa. Terjemahan bahasa yang dinonaktifkan tidak dihapus.') }}</p>
      <fieldset v-if="mst.l2" class="segfs"><legend>{{ t('Bahasa tampilan awal website') }}</legend>
        <div class="seg" role="radiogroup" :aria-label="t('Bahasa tampilan awal website')"><label v-for="c in [mst.l1, mst.l2]" :key="c" class="segopt"><input v-model="mst.dflt" type="radio" name="dflt" :value="c" /><span>{{ lim(c).name_native }}</span></label></div>
        <p class="hint">{{ t('Bahasa yang dilihat pengunjung pertama kali (alamat tanpa awalan). Pengunjung tetap bisa berganti bahasa. Isi yang belum diterjemahkan memakai bahasa utama.') }}</p></fieldset>
      <fieldset class="segfs"><legend>{{ t('Bahasa halaman admin (bawaan)') }}</legend>
        <div class="seg" role="radiogroup" :aria-label="t('Bahasa halaman admin (bawaan)')"><label class="segopt"><input v-model="mst.alang" type="radio" name="alang" value="id" /><span>Bahasa Indonesia</span></label><label class="segopt"><input v-model="mst.alang" type="radio" name="alang" value="en" /><span>English</span></label></div>
        <p class="hint">{{ t('Dipakai untuk akun yang belum memilih bahasa sendiri. Masing-masing akun tetap bisa berganti lewat tombol ID | EN.') }}</p></fieldset>
      <fieldset><legend>{{ t('Pilihan menu yang ditampilkan kepada owner & manager') }}</legend>
        <div class="opts"><label v-for="o in optionMeta()" :key="o[0]"><input v-model="mst.opts[o[0]]" type="checkbox" /> {{ o[1] }}</label></div>
        <p class="hint">{{ t('Mengganti tipe akan mengisi pilihan bawaan tipe itu (bisa diubah lagi). Pilihan yang dimatikan tidak muncul di form menu, dan data menu yang memakainya dikosongkan.') }}</p></fieldset>
      <p class="err">{{ mMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan konfigurasi') }}</button></div></form>
    </template>
  </div>
</template>
