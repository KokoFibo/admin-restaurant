<script setup lang="ts">
import { reactive, ref, watch } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { translate, trErr } from '../lib/api';
import { S, TYPES, TYPE_DEFAULTS, optionMeta, enabled, lim, load, toast } from '../store';
import Field from './Field.vue';
import PurgePanel from './PurgePanel.vue';
const p = reactive<any>({ phone: '', wa: '', email: '', maps: '', address: '', lunch: '', tea: '', dinner: '', tr: {} }), mst = reactive<any>({ type: 'vegan', alang: 'id', l1: 'id', l2: '', tz: 'Asia/Jakarta', opts: {} });
const pMsg = ref(''), mMsg = ref(''), bill = reactive<any>({ tax: 0, service: 0 }), bMsg = ref(''), mode = ref('photo'), dMsg = ref('');
function init() {
  const T = S.T, hr = T.opening_hours || {};
  Object.assign(p, { phone: T.phone || '', wa: T.whatsapp || '', email: T.email || '', maps: T.maps_url || '', address: T.address || '', lunch: hr.lunch || '', tea: hr.tea || '', dinner: hr.dinner || '' });
  p.tr = {}; S.TL.forEach((c: string) => { const r = S.tenTr.find((x: any) => x.lang === c) || {}; p.tr[c] = { brand: r.brand_name || '', tagline: r.tagline || '' }; });
  Object.assign(mst, { tz: T.timezone || 'Asia/Jakarta', type: T.restaurant_type, alang: T.admin_default_lang === 'en' ? 'en' : 'id', l1: S.TL[0], l2: S.TL[1] || '' });
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
const langs = () => S.langsAll.filter((l: any) => l.is_available);
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
async function saveMaster() {
  if (mst.l2 && mst.l1 === mst.l2) return (mMsg.value = t('Bahasa kedua tidak boleh sama dengan bahasa utama.'));
  if (!confirm(t('Simpan pengaturan master? Data menu yang memakai pilihan yang dimatikan akan dikosongkan.'))) return;
  const { error } = await sb.rpc('master_set_tenant_settings', { p_tenant: S.tid, p_type: mst.type, p_langs: mst.l2 ? [mst.l1, mst.l2] : [mst.l1], p_options: Object.keys(mst.opts).filter(k => mst.opts[k]), p_admin_lang: mst.alang });
  if (error) return (mMsg.value = error.message);
  if (mst.tz !== S.T.timezone) { const z = await sb.rpc('set_tenant_timezone', { p_tenant: S.tid, p_tz: mst.tz }); if (z.error) return (mMsg.value = z.error.message); }
  mMsg.value = ''; toast(t('Tersimpan')); load(true);
}
</script>
<template>
  <div>
    <form class="panel" @submit.prevent="saveProfile"><h3>{{ t('Profil & kontak') }}</h3>
      <div class="grid2"><label>{{ t('Telepon') }}<input v-model="p.phone" /></label><label>WhatsApp<input v-model="p.wa" /></label><label>Email<input v-model="p.email" /></label>
        <label>{{ t('Peta: tautan Google Maps') }}<input v-model="p.maps" placeholder="https://maps.app.goo.gl/…" /></label></div>
      <Field v-model="p.address" :label="t('Alamat (diisi satu kali, tidak diterjemahkan)')" :max="300" :rows="2" />
      <div class="grid2"><label>{{ t('Jam makan siang') }}<input v-model="p.lunch" placeholder="11:30-14:30" /></label><label>{{ t('Jam teh sore') }}<input v-model="p.tea" placeholder="14:30-17:00" /></label><label>{{ t('Jam makan malam') }}<input v-model="p.dinner" placeholder="17:30-21:30" /></label></div>
      <fieldset v-for="(c, i) in S.TL" :key="c"><legend>{{ lim(c).name_native }} {{ i === 0 ? t('— bahasa utama') : '' }}</legend>
        <Field v-model="p.tr[c].brand" :label="t('Nama brand')" :max="80" /><Field v-model="p.tr[c].tagline" :label="t('Slogan')" :max="160" /></fieldset>
      <div v-if="S.TL.length > 1" class="row"><button type="button" class="btn ghost" @click="trTagline">{{ t('Terjemahkan slogan') }}</button></div>
      <p class="err">{{ pMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan profil') }}</button></div></form>
    <form class="panel" @submit.prevent="saveDisplay"><h3>{{ t('Tampilan menu') }}</h3>
      <label class="chk"><input v-model="mode" type="radio" value="photo" /> {{ t('Dengan foto (kartu)') }}</label>
      <label class="chk"><input v-model="mode" type="radio" value="text" /> {{ t('Teks saja (daftar ringkas: nama, deskripsi, harga)') }}</label>
      <p class="hint">{{ t('Foto yang sudah diunggah tidak dihapus saat Anda berpindah mode, dan bisa dipakai lagi kapan saja. Foto hero dan banner tidak terpengaruh.') }}</p>
      <p class="err">{{ dMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan tampilan menu') }}</button></div></form>
    <form class="panel" @submit.prevent="saveBilling"><h3>{{ t('Pembayaran: pajak & biaya layanan') }}</h3>
      <div class="grid2"><label>{{ t('Biaya layanan (%)') }}<input v-model="bill.service" type="number" min="0" max="100" step="0.01" /></label><label>{{ t('Pajak (%)') }}<input v-model="bill.tax" type="number" min="0" max="100" step="0.01" /></label></div>
      <p class="hint">{{ t('Dihitung di tagihan: (subtotal − diskon) + biaya layanan, lalu pajak atas jumlah itu. Isi 0 bila tidak dipakai. Harga menu dianggap belum termasuk keduanya. Tagihan yang sudah lunas tidak berubah.') }}</p>
      <p class="err">{{ bMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan pembayaran') }}</button></div></form>
    <form v-if="S.isMaster" class="panel" @submit.prevent="saveMaster"><h3>{{ t('Pengaturan master') }} <small class="muted">{{ t('(hanya Super Admin)') }}</small></h3>
      <div class="grid2">
        <label>{{ t('Tipe restoran') }}<select v-model="mst.type" @change="onType"><option v-for="(v, k) in TYPES" :key="k" :value="k">{{ v }}</option></select></label>
        <label>{{ t('Bahasa halaman admin (bawaan)') }}<select v-model="mst.alang"><option value="id">Bahasa Indonesia</option><option value="en">English</option></select></label>
        <label>{{ t('Zona waktu restoran') }}<select v-model="mst.tz"><option value="Asia/Jakarta">WIB (Jakarta)</option><option value="Asia/Makassar">WITA (Makassar)</option><option value="Asia/Jayapura">WIT (Jayapura)</option></select></label>
        <label>{{ t('Bahasa utama') }}<select v-model="mst.l1"><option v-for="l in langs()" :key="l.code" :value="l.code">{{ l.name_native }}</option></select></label>
        <label>{{ t('Bahasa kedua (opsional)') }}<select v-model="mst.l2"><option value="">{{ t('— tidak ada —') }}</option><option v-for="l in langs()" :key="l.code" :value="l.code">{{ l.name_native }}</option></select></label></div>
      <fieldset><legend>{{ t('Pilihan menu yang ditampilkan kepada owner & manager') }}</legend>
        <div class="opts"><label v-for="o in optionMeta()" :key="o[0]"><input v-model="mst.opts[o[0]]" type="checkbox" /> {{ o[1] }}</label></div>
        <p class="hint">{{ t('Mengganti tipe akan mengisi pilihan bawaan tipe itu (bisa diubah lagi). Pilihan yang dimatikan tidak muncul di form menu, dan data menu yang memakainya dikosongkan.') }}</p></fieldset>
      <p class="hint">{{ t('Maksimal 2 bahasa. Terjemahan bahasa yang dinonaktifkan tidak dihapus.') }}</p>
      <p class="err">{{ mMsg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Simpan pengaturan master') }}</button></div></form>
    <p v-else class="hint">{{ t('Tipe restoran: {0} · Bahasa: {1}. Perubahan dilakukan oleh Super Admin.', TYPES[S.T.restaurant_type], S.TL.map((c: string) => lim(c).name_native).join(', ')) }}</p>
    <PurgePanel v-if="S.isMaster" />
  </div>
</template>
