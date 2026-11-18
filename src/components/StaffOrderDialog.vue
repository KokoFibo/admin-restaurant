<script setup lang="ts">
import { computed, reactive, ref } from 'vue';
import { t, rp } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { S, can, toast, takeawayName } from '../store';
import Modal from './Modal.vue';
/** "Pesanan baru" oleh staf: pilih meja (atau Kasir/take away), pilih menu, kirim. Langsung masuk dapur; ikut tagihan terbuka meja itu. */
const emit = defineEmits<{ (e: 'done'): void }>();
const m = ref<any>(), tables = ref<any[]>([]), menu = reactive<{ cats: any[]; items: any[] }>({ cats: [], items: [] }), qty = reactive<Record<string, number>>({});
const tableId = ref(''), name = ref(''), note = ref(''), msg = ref(''), busy = ref(false), loading = ref(false), q = ref('');
const tableOf = computed(() => tables.value.find(x => x.id === tableId.value));
const isCounter = computed(() => tableOf.value?.kind === 'counter');
const tableLabel = (x: any) => (x.kind === 'counter' ? takeawayName() : x.label) + (x.open_bill ? ' · ' + t('tagihan terbuka') : '');
const lines = computed(() => menu.items.filter(i => qty[i.id] > 0));
const total = computed(() => lines.value.reduce((s, i) => s + qty[i.id] * i.price, 0));
const count = computed(() => lines.value.reduce((s, i) => s + qty[i.id], 0));
const shown = (cat: string) => menu.items.filter(i => i.cat === cat && (!q.value.trim() || i.name.toLowerCase().includes(q.value.trim().toLowerCase())));
async function open() {
  msg.value = ''; name.value = ''; note.value = ''; q.value = ''; for (const k of Object.keys(qty)) delete qty[k];
  m.value.open(); loading.value = true;
  const [a, b] = await Promise.all([sb.rpc('list_staff_tables', { p_tenant: S.tid }), sb.rpc('staff_menu', { p_tenant: S.tid })]);
  loading.value = false;
  if (a.error || b.error) { msg.value = (a.error || b.error)!.message; return; }
  tables.value = a.data || []; menu.cats = b.data?.cats || []; menu.items = b.data?.items || [];
  if (!tableOf.value) tableId.value = tables.value[0]?.id || '';
}
const bump = (id: string, d: number) => { qty[id] = Math.max(0, Math.min(99, (qty[id] || 0) + d)); msg.value = ''; };
const ERR: Record<string, () => string> = {
  'E:name_required': () => t('Nama pelanggan wajib diisi untuk pesanan kasir.'), 'E:empty': () => t('Pilih minimal satu menu.'),
  'E:item_unavailable': () => t('Ada menu yang baru saja habis atau disembunyikan. Tutup dan buka lagi dialog ini untuk memuat ulang menu.'),
  'E:invalid_table': () => t('Meja tidak ditemukan atau sudah nonaktif.'),
};
async function submit() {
  if (!tableId.value) return (msg.value = t('Pilih meja.'));
  if (!count.value) return (msg.value = ERR['E:empty']());
  if (isCounter.value && !name.value.trim()) return (msg.value = ERR['E:name_required']());
  busy.value = true; msg.value = '';
  const { data, error } = await sb.rpc('place_staff_order', { p_tenant: S.tid, p_table: tableId.value, p_items: lines.value.map(i => ({ id: i.id, qty: qty[i.id] })), p_name: name.value.trim() || null, p_note: note.value.trim() || null });
  busy.value = false;
  if (error) return (msg.value = (ERR[error.message] || (() => error.message))());
  toast(t('Pesanan #{0} ({1}) dikirim ke dapur.', data.order_no, data.kind === 'counter' ? takeawayName() : data.table_label));
  m.value.close(); emit('done');
}
defineExpose({ open });
</script>
<template>
  <Modal ref="m">
    <form class="sod" @submit.prevent="submit">
      <h3>{{ t('Pesanan baru') }}</h3>
      <p v-if="loading" class="muted">{{ t('Memuat…') }}</p>
      <template v-else>
        <label>{{ t('Meja') }}<select v-model="tableId" required><option v-for="x in tables" :key="x.id" :value="x.id">{{ tableLabel(x) }}</option></select></label>
        <p v-if="tableOf?.open_bill" class="hint">{{ t('Pesanan ini akan masuk ke tagihan yang sedang terbuka di meja tersebut.') }}</p>
        <p v-else-if="isCounter" class="hint">{{ t('Setiap pesanan di sini menjadi tagihan tersendiri. Nama pelanggan wajib.') }}</p>
        <label>{{ isCounter ? t('Nama pelanggan') : t('Nama pelanggan (opsional)') }}<input v-model="name" maxlength="60" :required="isCounter" /></label>
        <input v-model="q" class="sodq" type="search" :placeholder="t('Cari menu…')" />
        <div class="sodmenu">
          <template v-for="c in menu.cats" :key="c.id">
            <template v-if="shown(c.id).length">
              <h4>{{ c.name }}</h4>
              <div v-for="i in shown(c.id)" :key="i.id" class="sodrow" :class="{ off: i.sold_out }">
                <span>{{ i.name }}<small v-if="i.sold_out"> · {{ t('habis') }}</small><small v-else-if="can.price()"> · {{ rp(i.price) }}</small></span>
                <span class="qtyc"><button type="button" :disabled="i.sold_out || !qty[i.id]" @click="bump(i.id, -1)" aria-label="−">−</button><output>{{ qty[i.id] || 0 }}</output><button type="button" :disabled="i.sold_out" @click="bump(i.id, 1)" aria-label="+">+</button></span>
              </div>
            </template>
          </template>
          <p v-if="!menu.items.length" class="muted">{{ t('Belum ada menu yang tampil.') }}</p>
        </div>
        <label>{{ t('Catatan (opsional)') }}<input v-model="note" maxlength="200" /></label>
        <p v-if="count" class="sodsum"><b>{{ count }} {{ t('item') }}</b><b v-if="can.price()"> · {{ rp(total) }}</b></p>
      </template>
      <p class="err" role="alert">{{ msg }}</p>
      <div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button class="btn vm" type="submit" :disabled="busy || loading">{{ t('Kirim ke dapur') }}</button></div>
    </form>
  </Modal>
</template>
