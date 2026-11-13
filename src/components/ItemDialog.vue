<script setup lang="ts">
import { nextTick, reactive, ref, watch } from 'vue';
import { t } from '../lib/i18n';
import { sb, media } from '../lib/supabase';
import { uploadImage, deleteImage, translate, trErr } from '../lib/api';
import { drawPreview, toWebp } from '../lib/image';
import { S, optionMeta, enabled, lim, itText, catName, load, toast } from '../store';
import Modal from './Modal.vue'; import Field from './Field.vue';
type Tr = { name: string; short: string; detail: string; badge: string };
const m = ref<any>(), it = ref<any>(null), msg = ref(''), saving = ref(false), hint = ref('');
const f = reactive<any>({ cat: '', price: 0, opts: {}, spicy: false, level: 1, vis: true, sold: false, lock: false, tr: {} as Record<string, Tr> });
let orig = { n: '', s: '', d: '', b: '' }, reviewed = false, aiFilled = false;
const photo = ref<HTMLImageElement | null>(null), px = ref(50), py = ref(50), prev = ref<HTMLCanvasElement>();
const opts = () => optionMeta().filter(o => o[0] !== 'is_spicy' && enabled(o[0]));

defineExpose({
  open(item?: any) {
    it.value = item || null; msg.value = ''; saving.value = false; photo.value = null; px.value = py.value = 50; reviewed = aiFilled = false;
    const first = item ? itText(item.id, S.TL[0]) : ({} as any);
    orig = { n: first.name || '', s: first.short_description || '', d: first.detail_description || '', b: first.badge || '' };
    f.cat = item?.category_id || S.cats[0]?.id || ''; f.price = item?.price_idr ?? ''; f.spicy = !!item?.is_spicy; f.level = item?.spice_level || 1;
    f.vis = !item || item.is_visible; f.sold = !!item?.is_sold_out; f.opts = Object.fromEntries(opts().map(o => [o[0], !!item?.[o[0]]]));
    f.tr = {}; S.TL.forEach((c: string) => { const r = item ? itText(item.id, c) : ({} as any); f.tr[c] = { name: r.name || '', short: r.short_description || '', detail: r.detail_description || '', badge: r.badge || '' }; });
    f.lock = S.TL[1] ? !!(item && itText(item.id, S.TL[1]).is_locked) : false;
    hint.value = t('Foto otomatis dipotong 4:3, dikecilkan ke 800 px, dan diubah ke WebP ringan (sekitar 60 KB) sebelum diunggah.');
    m.value.open();
  },
});
const redraw = () => nextTick(() => photo.value && prev.value && drawPreview(photo.value, prev.value, px.value, py.value));
watch([px, py, photo], redraw);
function onPhoto(e: any) {
  const file = e.target.files[0]; if (!file) return; const img = new Image();
  img.onload = () => { px.value = py.value = 50; photo.value = img;
    hint.value = img.naturalWidth < 600 ? t('⚠ Foto kecil ({0}px). Disarankan minimal 600px lebar agar tetap tajam.', img.naturalWidth) : t('Foto {0}×{1}px akan dipotong 4:3 dan dikecilkan ke 800 px (WebP).', img.naturalWidth, img.naturalHeight); };
  img.src = URL.createObjectURL(file);
}
const secInput = (e: any) => { if (e.target.type !== 'checkbox') { f.lock = true; aiFilled = false; } };
async function fillSecondary() {
  const p = S.TL[0], s = S.TL[1], src: Record<string, string> = {}, k4 = ['name', 'short', 'detail', 'badge'] as const;
  k4.forEach(k => { const v = (f.tr[p][k] || '').trim(); if (v) src[k] = v; });
  if (!Object.keys(src).length) return;
  try {
    const r = await translate(p, s, src);
    k4.forEach(k => { const max = k === 'name' ? lim(s).max_name : k === 'short' ? lim(s).max_short : k === 'detail' ? lim(s).max_detail : 40; f.tr[s][k] = (r.fields[k] ?? '').slice(0, max); });
    aiFilled = true; reviewed = true;
    msg.value = r.over?.length ? t('Sebagian terjemahan melebihi batas dan dipotong. Periksa lalu simpan.') : t('Periksa terjemahan di bawah, lalu tekan Simpan.');
  } catch (e: any) { reviewed = true; msg.value = trErr(e) + ' ' + t('Tekan Simpan lagi untuk menyimpan tanpa terjemahan (website memakai bahasa utama).'); }
}
async function retranslate() { f.lock = false; msg.value = t('Menerjemahkan…'); await fillSecondary(); }
async function submit() {
  const p = S.TL[0], P = f.tr[p];
  if (!P.name.trim() || !P.short.trim()) return (msg.value = t('Nama menu dan deskripsi singkat (bahasa utama) wajib diisi.'));
  if (!f.cat) return (msg.value = t('Pilih kategori.'));
  if (S.TL.length > 1) {
    const changed = P.name.trim() !== orig.n || P.short.trim() !== orig.s || P.detail.trim() !== orig.d || P.badge.trim() !== orig.b || !f.tr[S.TL[1]].name.trim();
    if (!f.lock && changed && !reviewed) { saving.value = true; msg.value = t('Menerjemahkan…'); await fillSecondary(); saving.value = false; return; }
  }
  saving.value = true; msg.value = t('Menyimpan…');
  try {
    let image_key = it.value?.image_key ?? null; const oldKey = image_key;
    if (photo.value) image_key = await uploadImage(await toWebp(photo.value, px.value, py.value), P.name);
    const tr = S.TL.map((c: string, i: number) => ({ lang: c, name: f.tr[c].name.trim(), short_description: f.tr[c].short.trim(), detail_description: f.tr[c].detail.trim(), badge: f.tr[c].badge.trim(),
      is_locked: i > 0 ? f.lock : false, source: i > 0 && aiFilled ? 'ai' : 'manual' })).filter((x: any) => x.name && x.short_description);
    const o = (k: string) => !!f.opts[k];
    const payload = { id: it.value?.id ?? null, tenant_id: S.tid, category_id: f.cat, price_idr: Math.max(0, Math.round(+f.price || 0)), image_key,
      has_egg: o('has_egg'), has_onion: o('has_onion'), is_non_halal: o('is_non_halal'), is_spicy: enabled('is_spicy') && f.spicy, spice_level: enabled('is_spicy') && f.spicy ? +f.level : null,
      is_visible: f.vis, is_sold_out: f.sold, tr };
    const { error } = await sb.rpc('save_menu_item', { p: payload });
    if (error) { if (photo.value && image_key !== oldKey) await deleteImage(image_key); throw error; }
    if (photo.value && oldKey && oldKey !== image_key) await deleteImage(oldKey);
    m.value.close(); toast(t('Tersimpan')); load();
  } catch (err: any) { msg.value = t('Gagal menyimpan: {0}', err?.message || err); }
  saving.value = false;
}
</script>
<template>
  <Modal ref="m"><form @submit.prevent="submit">
    <h3>{{ it ? t('Ubah menu') : t('Tambah menu') }}</h3>
    <div class="grid2">
      <label>{{ t('Kategori') }}<select v-model="f.cat"><option v-for="c in S.cats" :key="c.id" :value="c.id">{{ catName(c.id) }}</option></select></label>
      <label>{{ t('Harga (Rupiah)') }}<input v-model="f.price" type="number" min="0" step="1000" required /></label>
    </div>
    <div class="checks">
      <label v-for="o in opts()" :key="o[0]"><input v-model="f.opts[o[0]]" type="checkbox" /> {{ o[1] }}</label>
      <template v-if="enabled('is_spicy')"><label><input v-model="f.spicy" type="checkbox" /> {{ t('Pedas') }}</label>
        <label v-show="f.spicy">{{ t('Tingkat kepedasan') }} <select v-model="f.level"><option v-for="n in 5" :key="n" :value="n">{{ n }}</option></select></label></template>
      <label><input v-model="f.vis" type="checkbox" /> {{ t('Tampilkan di website') }}</label><label><input v-model="f.sold" type="checkbox" /> {{ t('Habis') }}</label>
    </div>
    <fieldset v-for="(code, idx) in S.TL" :key="code" @input="idx === 1 && secInput($event)">
      <legend>{{ lim(code).name_native }} {{ idx === 0 ? t('— bahasa utama') : t('— terjemahan AI (bisa diedit)') }}</legend>
      <Field v-model="f.tr[code].name" :label="t('Nama menu')" :max="lim(code).max_name" />
      <Field v-model="f.tr[code].short" :label="t('Deskripsi singkat')" :max="lim(code).max_short" :rows="3" />
      <Field v-model="f.tr[code].detail" :label="t('Detail menu (opsional — tampil saat kartu di-hover)')" :max="lim(code).max_detail" :rows="5" />
      <Field v-model="f.tr[code].badge" :label="t('Label (opsional, mis. &quot;Pilihan Chef&quot;)')" :max="40" />
      <div v-if="idx > 0" class="checks"><label><input v-model="f.lock" type="checkbox" /> {{ t('Kunci terjemahan (tidak ditimpa otomatis)') }}</label><button type="button" class="btn ghost" @click="retranslate">{{ t('Terjemahkan ulang') }}</button></div>
    </fieldset>
    <fieldset v-if="S.T?.menu_display !== 'text'"><legend>{{ t('Foto') }}</legend>
      <img v-if="it?.image_key && !photo" id="oldImg" alt="" :src="media(it.image_key)" /><canvas v-show="photo" id="prev" ref="prev" width="320" height="240" />
      <input type="file" accept="image/*" @change="onPhoto" />
      <div v-if="photo" class="grid2"><label>{{ t('Geser kiri-kanan') }}<input v-model.number="px" type="range" min="0" max="100" /></label><label>{{ t('Geser atas-bawah') }}<input v-model.number="py" type="range" min="0" max="100" /></label></div>
      <p class="hint">{{ hint }}</p></fieldset>
    <p class="err">{{ msg }}</p>
    <div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button type="submit" class="btn vm" :disabled="saving">{{ t('Simpan') }}</button></div>
  </form></Modal>
</template>
