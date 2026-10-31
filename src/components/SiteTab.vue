<script setup lang="ts">
import { nextTick, onMounted, reactive, ref, watch } from 'vue';
import { t } from '../lib/i18n';
import { sb, media } from '../lib/supabase';
import { uploadImage, deleteImage, translate, trErr } from '../lib/api';
import { drawPreview, toWebp } from '../lib/image';
import { S, lim, toast } from '../store';
import Field from './Field.vue'; import ThemeSection from './ThemeSection.vue';
/** Hero website (hanya Owner / Super Admin). Kolom kosong = website memakai teks bawaan template. */
const FIELDS: { k: string; label: () => string; max: number; rows?: number }[] = [
  { k: 'eyebrow', label: () => t('Label kecil di atas judul'), max: 60 },
  { k: 'title', label: () => t('Judul — kalimat biasa'), max: 120 },
  { k: 'title_em', label: () => t('Judul — kalimat yang ditekankan'), max: 120 },
  { k: 'lead', label: () => t('Deskripsi'), max: 400, rows: 4 },
  { k: 'chip1', label: () => t('Chip 1'), max: 40 }, { k: 'chip2', label: () => t('Chip 2'), max: 40 }, { k: 'chip3', label: () => t('Chip 3'), max: 40 },
  { k: 'cta_order', label: () => t('Teks tombol pesan'), max: 30 }, { k: 'cta_menu', label: () => t('Teks tombol menu'), max: 30 },
];
const RATIO = 4 / 5;
const f = reactive<any>({ tr: {}, lock: false }), imageKey = ref(''), removeImg = ref(false), msg = ref(''), saving = ref(false), loaded = ref(false);
const photo = ref<HTMLImageElement | null>(null), px = ref(50), py = ref(50), prev = ref<HTMLCanvasElement>();
async function load() {
  const id = S.tid;
  const [tx, tr, im] = await Promise.all([sb.from('site_texts').select('id,key').eq('tenant_id', id), sb.from('site_text_translations').select('site_text_id,lang,value,is_locked').eq('tenant_id', id), sb.from('site_images').select('slot,image_key').eq('tenant_id', id)]);
  const bad = [tx, tr, im].find((x: any) => x.error); if (bad) return toast(bad.error.message);
  const key = Object.fromEntries((tx.data || []).map((x: any) => [x.id, x.key.replace(/^hero\./, '')]));
  f.tr = {}; S.TL.forEach((l: string) => (f.tr[l] = Object.fromEntries(FIELDS.map(x => [x.k, '']))));
  (tr.data || []).forEach((r: any) => { if (key[r.site_text_id] && f.tr[r.lang]) f.tr[r.lang][key[r.site_text_id]] = r.value; });
  f.lock = !!S.TL[1] && (tr.data || []).some((r: any) => r.lang === S.TL[1] && r.is_locked);
  imageKey.value = (im.data || []).find((x: any) => x.slot === 'hero')?.image_key || ''; loaded.value = true;
}
onMounted(load);
watch([px, py, photo], () => nextTick(() => photo.value && prev.value && drawPreview(photo.value, prev.value, px.value, py.value, RATIO)));
function onPhoto(e: any) { const file = e.target.files[0]; if (!file) return; const img = new Image(); img.onload = () => { px.value = py.value = 50; removeImg.value = false; photo.value = img; }; img.src = URL.createObjectURL(file); }
const secInput = (e: any) => { if (e.target.type !== 'checkbox') f.lock = true; };
async function aiFill() {
  const p = S.TL[0], s = S.TL[1], src: Record<string, string> = {}; FIELDS.forEach(x => { const v = (f.tr[p][x.k] || '').trim(); if (v) src[x.k] = v; });
  if (!Object.keys(src).length) return; msg.value = t('Menerjemahkan…');
  try { const r = await translate(p, s, src); FIELDS.forEach(x => { if (r.fields[x.k] != null) f.tr[s][x.k] = String(r.fields[x.k]).slice(0, x.max); }); f.lock = false; msg.value = t('Periksa terjemahan di bawah, lalu tekan Simpan.'); }
  catch (e: any) { msg.value = trErr(e); }
}
async function save() {
  saving.value = true; msg.value = t('Menyimpan…'); const old = imageKey.value; let newKey: string | null = null;
  try {
    const p: any = { tenant_id: S.tid, texts: {}, locks: S.TL[1] ? { [S.TL[1]]: f.lock } : {} };
    FIELDS.forEach(x => { p.texts['hero.' + x.k] = Object.fromEntries(S.TL.map((l: string) => [l, (f.tr[l][x.k] || '').trim()])); });
    if (photo.value) { newKey = await uploadImage(await toWebp(photo.value, px.value, py.value, { ratio: RATIO, width: 900, maxBytes: 140 * 1024 }), 'hero', 'site'); p.image_key = newKey; }
    else if (removeImg.value) p.image_key = '';
    const { error } = await sb.rpc('save_site_hero', { p }); if (error) { if (newKey) await deleteImage(newKey); throw error; }
    if (old && (newKey || removeImg.value)) await deleteImage(old);
    toast(t('Tersimpan')); msg.value = ''; photo.value = null; removeImg.value = false; await load();
  } catch (e: any) { msg.value = t('Gagal menyimpan: {0}', e?.message || e); }
  saving.value = false;
}
</script>
<template>
  <div>
  <ThemeSection />
  <form v-if="loaded" class="panel" @submit.prevent="save">
    <h3>{{ t('Hero website') }}</h3>
    <p class="hint">{{ t('Bagian paling atas website. Kolom yang dikosongkan memakai teks dan foto bawaan template. Hanya Owner yang bisa mengubahnya.') }}</p>
    <fieldset><legend>{{ t('Foto hero') }}</legend>
      <img v-if="imageKey && !photo && !removeImg" :src="media(imageKey)" alt="" style="max-width:240px;border-radius:8px" /><p v-else-if="!photo" class="muted">{{ t('Memakai foto bawaan template.') }}</p>
      <canvas v-show="photo" ref="prev" width="240" height="300" style="border-radius:8px" />
      <input type="file" accept="image/*" @change="onPhoto" />
      <div v-if="photo" class="grid2"><label>{{ t('Geser kiri-kanan') }}<input v-model.number="px" type="range" min="0" max="100" /></label><label>{{ t('Geser atas-bawah') }}<input v-model.number="py" type="range" min="0" max="100" /></label></div>
      <label v-if="imageKey && !photo" class="checks" style="display:flex"><input v-model="removeImg" type="checkbox" /> {{ t('Hapus foto ini (kembali ke foto bawaan)') }}</label>
      <p class="hint">{{ t('Foto dipotong portrait 4:5 dan diubah ke WebP sebelum diunggah.') }}</p></fieldset>
    <fieldset v-for="(code, idx) in S.TL" :key="code" @input="idx === 1 && secInput($event)">
      <legend>{{ lim(code).name_native }} {{ idx === 0 ? t('— bahasa utama') : t('— terjemahan AI (bisa diedit)') }}</legend>
      <Field v-for="x in FIELDS" :key="x.k" v-model="f.tr[code][x.k]" :label="x.label()" :max="x.max" :rows="x.rows" />
      <div v-if="idx > 0" class="checks"><label><input v-model="f.lock" type="checkbox" /> {{ t('Kunci terjemahan (tidak ditimpa otomatis)') }}</label><button type="button" class="btn ghost" @click="aiFill">{{ t('Terjemahkan dari bahasa utama') }}</button></div>
    </fieldset>
    <p class="err">{{ msg }}</p><div class="row"><button class="btn vm" type="submit" :disabled="saving">{{ t('Simpan') }}</button></div>
  </form>
  <p v-else class="muted">{{ t('Memuat…') }}</p>
  </div>
</template>
