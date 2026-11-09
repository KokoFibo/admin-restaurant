<script setup lang="ts">
import { computed, ref } from 'vue';
import { t, rp } from '../lib/i18n';
import { sb, media } from '../lib/supabase';
import { deleteImage } from '../lib/api';
import { vSortable } from '../lib/sortable';
import { S, ROLE_LABEL, can, role, itText, catName, load, run, toast } from '../store';
import ItemDialog from './ItemDialog.vue';
const dlg = ref<any>();
const active = computed(() => S.items.filter((i: any) => !i.archived_at)), archived = computed(() => S.items.filter((i: any) => i.archived_at));
const inCat = (id: string) => active.value.filter((i: any) => i.category_id === id);
const name = (i: any) => itText(i.id, S.TL[0]).name || t('(tanpa nama)');
const flags = (i: any) => [i.has_egg && t('telur'), i.has_onion && t('bawang'), i.is_non_halal && t('non halal'), i.is_spicy && t('pedas {0}/5', i.spice_level), i.is_sold_out && t('HABIS'), !i.is_visible && t('tersembunyi')].filter(Boolean).join(' · ');
const sortOpts = (catId: string) => ({ enabled: can.edit(), ids: inCat(catId).map((i: any) => i.id), onSort: (ids: string[]) => run(sb.rpc('reorder_menu_items', { p_tenant: S.tid, p_category: catId, p_ids: ids }), t('Urutan disimpan')) });
const feature = (i: any) => run(sb.from('menu_items').update({ is_featured: !i.is_featured }).eq('id', i.id));
const arch = (i: any) => confirm(t('Arsipkan "{0}"? Menu disembunyikan dan bisa dipulihkan dari Arsip.', name(i))) && run(sb.from('menu_items').update({ archived_at: new Date().toISOString() }).eq('id', i.id), t('Diarsipkan'));
async function del(i: any) {   // hapus permanen: baris menu dulu, lalu fotonya di R2
  if (!confirm(t('Hapus menu "{0}" beserta fotonya? Tidak bisa dibatalkan.', name(i)))) return;
  const { error } = await sb.from('menu_items').delete().eq('id', i.id); if (error) return toast(error.message);
  await deleteImage(i.image_key); toast(t('Menu dan fotonya dihapus')); load();
}
</script>
<template>
  <div>
    <div v-if="can.edit()" class="bar"><button class="btn vm" @click="dlg.open()">{{ t('+ Tambah menu') }}</button></div>
    <p v-else class="hint">{{ t('Role {0}: {1}', ROLE_LABEL[role()], can.sold() ? t('Anda dapat menandai menu Habis / Tersedia.') : t('hanya melihat menu.')) }}</p>
    <p v-if="!S.cats.length" class="muted">{{ t('Belum ada kategori.') }}</p>
    <template v-for="c in S.cats" :key="c.id">
      <h3>{{ catName(c.id) }} <small>{{ S.TL.slice(1).map((x: string) => catName(c.id, x)).join(' · ') }}</small></h3>
      <div v-sortable="sortOpts(c.id)">
        <div v-for="i in inCat(c.id)" :key="i.id" class="arow" :class="{ dim: !i.is_visible }">
          <span v-if="can.edit()" class="drag" :title="t('Geser untuk mengurutkan')">⠿</span><span v-else />
          <img v-if="i.image_key" class="th" :src="media(i.image_key)" alt="" loading="lazy" /><div v-else class="th">{{ (name(i) || '?')[0] }}</div>
          <div><b>{{ name(i) }}</b><span class="muted">{{ can.price() ? rp(i.price_idr) : '' }}{{ flags(i) ? (can.price() ? ' · ' : '') + flags(i) : '' }}</span></div>
          <div class="acts">
            <button v-if="can.edit()" class="star" :class="{ on: i.is_featured }" :title="t('Hidangan unggulan di Beranda (maks 6)')" @click="feature(i)">{{ i.is_featured ? '★' : '☆' }}</button>
            <button v-if="can.sold()" @click="run(sb.rpc('set_sold_out', { p_item: i.id, p_value: !i.is_sold_out }))">{{ i.is_sold_out ? t('Tersedia') : t('Habis') }}</button>
            <template v-if="can.edit()">
              <button @click="run(sb.from('menu_items').update({ is_visible: !i.is_visible }).eq('id', i.id))">{{ i.is_visible ? t('Sembunyikan') : t('Tampilkan') }}</button>
              <button @click="dlg.open(i)">{{ t('Ubah') }}</button><button @click="arch(i)">{{ t('Arsipkan') }}</button><button class="danger" @click="del(i)">{{ t('Hapus') }}</button>
            </template>
          </div>
        </div>
      </div>
      <p v-if="!inCat(c.id).length" class="muted">{{ t('Belum ada menu.') }}</p>
    </template>
    <template v-if="archived.length && can.edit()">
      <h3>{{ t('Arsip') }}</h3>
      <div v-for="i in archived" :key="i.id" class="arow dim"><span /><div class="th">{{ (name(i) || '?')[0] }}</div><div><b>{{ name(i) }}</b></div>
        <div class="acts"><button @click="run(sb.from('menu_items').update({ archived_at: null }).eq('id', i.id), t('Dipulihkan'))">{{ t('Pulihkan') }}</button><button class="danger" @click="del(i)">{{ t('Hapus') }}</button></div></div>
    </template>
    <ItemDialog ref="dlg" />
  </div>
</template>
