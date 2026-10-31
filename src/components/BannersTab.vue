<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { translate, trErr } from '../lib/api';
import { S, lim, toast } from '../store';
import Modal from './Modal.vue'; import Field from './Field.vue';
const rows = ref<any[]>([]), trs = ref<any[]>([]), loaded = ref(false), m = ref<any>(), cur = ref<any>(null), msg = ref(''), saving = ref(false);
const f = reactive<any>({ kind: 'info', starts_on: '', ends_on: '', scope: 'all', link_url: '', blocks: false, active: true, lock: false, tr: {} });
const today = () => new Date().toLocaleDateString('sv-SE', { timeZone: S.T.timezone || 'Asia/Jakarta' });
const KIND = () => ({ info: 'Info', promo: 'Promo', holiday: t('Libur') } as Record<string, string>);
const SCOPE = () => ({ all: t('Semua halaman'), home: t('Hanya Beranda'), order: t('Hanya halaman Order') } as Record<string, string>);
async function load() {
  const [b, x] = await Promise.all([sb.from('site_banners').select('*').eq('tenant_id', S.tid).order('starts_on', { ascending: false }), sb.from('site_banner_translations').select('*').eq('tenant_id', S.tid)]);
  if (b.error) return toast(b.error.message); rows.value = b.data || []; trs.value = x.data || []; loaded.value = true;
}
onMounted(load);
const status = (r: any) => !r.is_active ? 'off' : today() < r.starts_on ? 'soon' : today() > r.ends_on ? 'ended' : 'live';
const STATUS = () => ({ off: t('Nonaktif'), soon: t('Terjadwal'), ended: t('Berakhir'), live: t('Tayang') } as Record<string, string>);
const text = (r: any) => (trs.value.find(x => x.banner_id === r.id && x.lang === S.TL[0]) || trs.value.find(x => x.banner_id === r.id) || {}).message || '';
const liveCount = computed(() => rows.value.filter(r => r.is_active && today() <= r.ends_on).length);
function open(r?: any) {
  cur.value = r || null; msg.value = ''; const d = today();
  Object.assign(f, { kind: r?.kind || 'info', starts_on: r?.starts_on || d, ends_on: r?.ends_on || d, scope: r?.scope || 'all', link_url: r?.link_url || '', blocks: !!r?.blocks_orders, active: r ? r.is_active : true });
  f.tr = {}; S.TL.forEach((l: string) => { const x = r ? trs.value.find(y => y.banner_id === r.id && y.lang === l) : null; f.tr[l] = { message: x?.message || '', label: x?.link_label || '' }; });
  f.lock = !!(r && S.TL[1] && trs.value.find(y => y.banner_id === r.id && y.lang === S.TL[1])?.is_locked); m.value.open();
}
const secInput = (e: any) => { if (e.target.type !== 'checkbox') f.lock = true; };
async function aiFill() {
  const p = S.TL[0], s = S.TL[1], src: Record<string, string> = {}; if (f.tr[p].message.trim()) src.message = f.tr[p].message.trim(); if (f.tr[p].label.trim()) src.label = f.tr[p].label.trim();
  if (!src.message) return; msg.value = t('Menerjemahkan…');
  try { const r = await translate(p, s, src); f.tr[s].message = (r.fields.message || '').slice(0, 140); f.tr[s].label = (r.fields.label || '').slice(0, 30); f.lock = false; msg.value = t('Periksa terjemahan, lalu simpan.'); } catch (e: any) { msg.value = trErr(e); }
}
async function submit() {
  if (!f.tr[S.TL[0]].message.trim()) return (msg.value = t('Teks banner (bahasa utama) wajib diisi.'));
  saving.value = true; msg.value = t('Menyimpan…');
  const tr = S.TL.map((l: string, i: number) => ({ lang: l, message: f.tr[l].message.trim(), link_label: f.tr[l].label.trim(), is_locked: i > 0 ? f.lock : false, source: 'manual' })).filter((x: any) => x.message);
  const p = { id: cur.value?.id ?? null, tenant_id: S.tid, kind: f.kind, starts_on: f.starts_on, ends_on: f.ends_on, scope: f.scope, link_url: f.link_url.trim(), blocks_orders: f.kind === 'holiday' && f.blocks, is_active: f.active, tr };
  const { error } = await sb.rpc('save_banner', { p }); saving.value = false;
  if (error) return (msg.value = error.message); m.value.close(); toast(t('Tersimpan')); load();
}
async function toggle(r: any) { const { error } = await sb.from('site_banners').update({ is_active: !r.is_active }).eq('id', r.id); if (error) return toast(error.message); load(); }
async function del(r: any) { if (!confirm(t('Hapus banner ini?'))) return; const { error } = await sb.from('site_banners').delete().eq('id', r.id); if (error) return toast(error.message); toast(t('Dihapus')); load(); }
</script>
<template>
  <div>
    <div class="bar"><button class="btn vm" @click="open()">{{ t('+ Tambah banner') }}</button></div>
    <p class="hint">{{ t('Banner tampil otomatis pada tanggal mulai dan hilang setelah tanggal selesai (mengikuti zona waktu restoran). Maksimal 3 banner aktif sekaligus ({0} saat ini).', liveCount) }}</p>
    <p v-if="loaded && !rows.length" class="muted">{{ t('Belum ada banner.') }}</p>
    <div v-for="r in rows" :key="r.id" class="arow" :class="{ dim: status(r) === 'off' || status(r) === 'ended' }"><span /><span class="badge" :class="{ live: status(r) === 'live', holiday: r.kind === 'holiday' }">{{ KIND()[r.kind] }}</span>
      <div><b>{{ text(r) }}</b><span class="muted">{{ r.starts_on }} → {{ r.ends_on }} · {{ STATUS()[status(r)] }} · {{ SCOPE()[r.scope] }}{{ r.blocks_orders ? ' · ' + t('menutup pemesanan') : '' }}</span></div>
      <div class="acts"><button @click="toggle(r)">{{ r.is_active ? t('Nonaktifkan') : t('Aktifkan') }}</button><button @click="open(r)">{{ t('Ubah') }}</button><button class="danger" @click="del(r)">{{ t('Hapus') }}</button></div></div>
    <Modal ref="m"><form @submit.prevent="submit">
      <h3>{{ cur ? t('Ubah banner') : t('Tambah banner') }}</h3>
      <div class="grid2"><label>{{ t('Jenis') }}<select v-model="f.kind"><option value="info">Info</option><option value="promo">Promo</option><option value="holiday">{{ t('Libur') }}</option></select></label>
        <label>{{ t('Tampil di') }}<select v-model="f.scope"><option v-for="(v, k) in SCOPE()" :key="k" :value="k">{{ v }}</option></select></label>
        <label>{{ t('Tanggal mulai') }}<input v-model="f.starts_on" type="date" required /></label><label>{{ t('Tanggal selesai') }}<input v-model="f.ends_on" type="date" required :min="f.starts_on" /></label></div>
      <label>{{ t('Tautan (opsional, diawali https:// atau /)') }}<input v-model="f.link_url" maxlength="300" placeholder="https://… / /menu" /></label>
      <div class="checks"><label v-if="f.kind === 'holiday'"><input v-model="f.blocks" type="checkbox" /> {{ t('Nonaktifkan pemesanan QR selama periode ini') }}</label><label><input v-model="f.active" type="checkbox" /> {{ t('Aktif') }}</label></div>
      <fieldset v-for="(l, i) in S.TL" :key="l" @input="i === 1 && secInput($event)"><legend>{{ lim(l).name_native }} {{ i === 0 ? t('— bahasa utama') : t('— terjemahan AI (bisa diedit)') }}</legend>
        <Field v-model="f.tr[l].message" :label="t('Teks banner')" :max="140" :rows="2" /><Field v-model="f.tr[l].label" :label="t('Teks tombol tautan (opsional)')" :max="30" />
        <div v-if="i > 0" class="checks"><label><input v-model="f.lock" type="checkbox" /> {{ t('Kunci terjemahan (tidak ditimpa otomatis)') }}</label><button type="button" class="btn ghost" @click="aiFill">{{ t('Terjemahkan dari bahasa utama') }}</button></div></fieldset>
      <p class="err">{{ msg }}</p><div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button type="submit" class="btn vm" :disabled="saving">{{ t('Simpan') }}</button></div>
    </form></Modal>
  </div>
</template>
