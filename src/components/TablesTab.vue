<script setup lang="ts">
import { ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { S, siteBase, loadTables, qrList, toast, run, lbl, takeawayName } from '../store';
import Modal from './Modal.vue';
const m = ref<any>(), cur = ref<any>(null), label = ref(''), msg = ref('');
const base = () => siteBase();
const open = (tb?: any) => { cur.value = tb || null; label.value = tb?.label || ''; msg.value = ''; m.value.open(); };
async function submit() {
  const l = label.value.trim(); if (!l) return;
  const q = cur.value ? sb.from('restaurant_tables').update({ label: l }).eq('id', cur.value.id) : sb.from('restaurant_tables').insert({ tenant_id: S.tid, label: l, sort: (Math.max(0, ...S.tables.map((x: any) => x.sort)) || 0) + 10 });
  const { error } = await q; if (error) return (msg.value = error.code === '23505' ? t('Nama meja sudah dipakai.') : error.message);
  m.value.close(); toast(t('Tersimpan')); loadTables();
}
const toggle = async (tb: any) => { await run(sb.from('restaurant_tables').update({ is_active: !tb.is_active }).eq('id', tb.id)); loadTables(); };
async function rotate(tb: any) {
  if (!confirm(t('Ganti QR meja "{0}"? QR yang sudah dicetak tidak akan berlaku lagi.', tb.label))) return;
  const { error } = await sb.rpc('rotate_table_token', { p_table: tb.id }); if (error) return toast(error.message); toast(t('QR diganti. Cetak ulang QR meja ini.')); loadTables();
}
async function del(tb: any) {
  if (!confirm(t('Hapus meja "{0}"? Riwayat pesanan tetap ada.', tb.label))) return;
  const { error } = await sb.from('restaurant_tables').delete().eq('id', tb.id); if (error) return toast(error.message); toast(t('Dihapus')); loadTables();
}
const hasCounter = () => S.tables.some((x: any) => x.kind === 'counter');
/** QR Kasir (take away): satu per restoran. Namanya mengikuti istilah "take away" yang diatur Owner di Pengaturan. */
async function addCounter() {
  const { error } = await sb.from('restaurant_tables').insert({ tenant_id: S.tid, label: takeawayName(), sort: 9000, kind: 'counter' });
  if (error) return toast(error.code === '23505' ? t('Nama "{0}" sudah dipakai oleh meja lain. Ganti nama meja itu dulu.', takeawayName()) : error.message);
  toast(t('QR kasir dibuat. Cetak dan letakkan di kasir.')); loadTables();
}
const showQr = (list: any[]) => (base() ? (qrList.value = list) : toast(t('QR belum bisa dibuat: alamat website restoran belum diisi. Tambahkan domain di tabel tenant_domains atau isi PUBLIC_BASE_DOMAIN.')));
</script>
<template>
  <div>
    <div class="bar"><button class="btn vm" @click="open()">{{ t('+ Tambah meja') }}</button> <button v-if="!hasCounter()" class="btn ghost" @click="addCounter">{{ lbl('add_counter_qr', t('+ Tambah QR {0}', takeawayName())) }}</button> <button class="btn ghost" @click="showQr(S.tables.filter((x: any) => x.is_active))">{{ t('Cetak semua QR') }}</button></div>
    <p class="hint">{{ t('Tiap meja punya QR berbeda. Pelanggan hanya bisa memesan setelah memindai QR di meja; nomor meja otomatis ikut terkirim.') }}</p>
    <p class="hint">{{ t('QR kasir: untuk pelanggan yang datang langsung dan ingin membawa pulang. Pelanggan memindai di kasir, mengisi nama, dan tiap pesanan menjadi tagihan sendiri. Nama QR ini mengikuti istilah di Pengaturan.') }}</p>
    <p v-if="!base() || base().includes('localhost')" class="err">{{ t('QR memakai alamat {0}. Pasang domain restoran lebih dulu agar QR yang dicetak benar.', base() || '—') }}</p>
    <p v-else class="hint">{{ t('Alamat QR: {0}', base()) }}</p>
    <div v-for="tb in S.tables" :key="tb.id" class="arow" :class="{ dim: !tb.is_active }"><span /><div class="th">▦</div><div><b>{{ tb.label }}<span v-if="tb.kind === 'counter'" class="tag-kasir">{{ t('QR kasir') }}</span></b><span class="muted">{{ tb.is_active ? t('Aktif') : t('Nonaktif') }}</span></div>
      <div class="acts"><button @click="showQr([tb])">QR</button><button @click="toggle(tb)">{{ tb.is_active ? t('Nonaktifkan') : t('Aktifkan') }}</button><button @click="rotate(tb)">{{ t('Ganti QR') }}</button><button v-if="tb.kind !== 'counter'" @click="open(tb)">{{ t('Ubah nama') }}</button><button class="danger" @click="del(tb)">{{ t('Hapus') }}</button></div></div>
    <p v-if="!S.tables.length" class="muted">{{ t('Belum ada meja.') }}</p>
    <Modal ref="m"><form @submit.prevent="submit"><h3>{{ cur ? t('Ubah nama meja') : t('Tambah meja') }}</h3>
      <label>{{ t('Nama meja (mis. Meja 5, VIP 1)') }}<input v-model="label" maxlength="30" required /></label><p class="err">{{ msg }}</p>
      <div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button class="btn vm" type="submit">{{ t('Simpan') }}</button></div></form></Modal>
  </div>
</template>
