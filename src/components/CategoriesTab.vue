<script setup lang="ts">
import { reactive, ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { translate, trErr } from '../lib/api';
import { vSortable } from '../lib/sortable';
import { S, can, catName, lim, load, run, toast } from '../store';
import Modal from './Modal.vue'; import Field from './Field.vue';
const m = ref<any>(), cur = ref<any>(null), msg = ref(''), names = reactive<Record<string, string>>({});
const sortOpts = () => ({ enabled: can.edit(), ids: S.cats.map((c: any) => c.id), onSort: (ids: string[]) => run(sb.rpc('reorder_categories', { p_tenant: S.tid, p_ids: ids }), t('Urutan disimpan')) });
const count = (id: string) => S.items.filter((i: any) => i.category_id === id && !i.archived_at).length;
function open(c?: any) { cur.value = c || null; msg.value = ''; S.TL.forEach((l: string) => (names[l] = c && catName(c.id, l) !== t('(tanpa nama)') ? catName(c.id, l) : '')); m.value.open(); }
async function trCat() {
  const v = names[S.TL[0]].trim(); if (!v) return; msg.value = t('Menerjemahkan…');
  try { const r = await translate(S.TL[0], S.TL[1], { category: v }); names[S.TL[1]] = (r.fields.category || '').slice(0, 60); msg.value = ''; } catch (e: any) { msg.value = trErr(e); }
}
const slugify = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'kategori';
async function submit() {
  const name = names[S.TL[0]].trim(); if (!name) return;
  if (S.TL.length > 1 && !names[S.TL[1]].trim()) await trCat();
  const tr = S.TL.map((l: string) => ({ lang: l, name: (names[l] || '').trim() })).filter((x: any) => x.name);
  const p = { id: cur.value?.id ?? null, tenant_id: S.tid, slug: cur.value ? undefined : slugify(name) + '-' + Math.random().toString(36).slice(2, 5), is_visible: cur.value ? cur.value.is_visible : true, tr };
  const { error } = await sb.rpc('save_category', { p }); if (error) return (msg.value = error.message);
  m.value.close(); toast(t('Tersimpan')); load();
}
async function del(c: any) {
  if (!confirm(t('Hapus kategori "{0}"?', catName(c.id)))) return;
  const { error } = await sb.from('categories').delete().eq('id', c.id); if (error) return toast(t('Kategori masih berisi menu (pindahkan atau hapus dulu menunya).')); toast(t('Dihapus')); load();
}
</script>
<template>
  <div>
    <div class="bar"><button class="btn vm" @click="open()">{{ t('+ Tambah kategori') }}</button></div>
    <p class="hint">{{ t('Geser ⠿ untuk mengatur urutan kategori; urutan yang sama tampil di website.') }}</p>
    <div v-sortable="sortOpts()">
      <div v-for="c in S.cats" :key="c.id" class="arow"><span class="drag">⠿</span><div class="th">{{ (catName(c.id) || '?')[0] }}</div>
        <div><b>{{ catName(c.id) }}</b><span class="muted">{{ S.TL.slice(1).map((x: string) => catName(c.id, x)).join(' · ') }} · {{ t('{0} menu', count(c.id)) }}</span></div>
        <div class="acts"><button @click="open(c)">{{ t('Ubah') }}</button><button class="danger" @click="del(c)">{{ t('Hapus') }}</button></div></div>
    </div>
    <Modal ref="m"><form @submit.prevent="submit">
      <h3>{{ cur ? t('Ubah kategori') : t('Tambah kategori') }}</h3>
      <fieldset v-for="(l, i) in S.TL" :key="l"><legend>{{ lim(l).name_native }} {{ i === 0 ? t('— bahasa utama') : t('— terjemahan AI (bisa diedit)') }}</legend><Field v-model="names[l]" :label="t('Nama kategori')" :max="60" /></fieldset>
      <p class="err">{{ msg }}</p>
      <div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button v-if="S.TL.length > 1" type="button" class="btn ghost" @click="trCat">{{ t('Terjemahkan') }}</button><button type="submit" class="btn vm">{{ t('Simpan') }}</button></div>
    </form></Modal>
  </div>
</template>
