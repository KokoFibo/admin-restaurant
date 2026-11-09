<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';
import { t, rp } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { S, can, toast, loadBillReqs } from '../store';
import Modal from './Modal.vue';

type Row = { method: string; amount: number | ''; tendered: number | '' };
const bills = ref<any[]>([]), scope = ref<'open' | 'closed'>('open'), loaded = ref(false);
const pay = reactive<Record<string, { rows: Row[]; touched: boolean }>>({}), disc = reactive<Record<string, number | ''>>({}), discTouched = reactive<Record<string, boolean>>({});
const sel = reactive<Record<string, boolean>>({}), busyBill = ref('');
const METHODS = () => ({ cash: t('Tunai'), card: t('Kartu'), qris: 'QRIS', other: t('Lainnya') } as Record<string, string>);
const STATUS = () => ({ new: t('Baru'), preparing: t('Diproses'), ready: t('Siap'), done: t('Selesai'), cancelled: t('Batal') } as Record<string, string>);
const total = (b: any) => Number(b.figures?.total || 0);
const title = (b: any) => '#' + String(b.bill_no).padStart(4, '0');
const where = (b: any) => (b.tables?.length ? b.tables.map((x: any) => x.label).join(' + ') : b.label || '—');
const hm = (d: string) => new Date(d).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
const num = (v: any) => (v === '' || v == null ? 0 : Number(v) || 0);

/** Pesanan dikelompokkan per pelanggan (perangkat); tanpa perangkat = per pesanan. */
function groups(b: any) {
  const m = new Map<string, any>();
  for (const o of b.orders) {
    const k = o.client_id || o.id; let g = m.get(k);
    if (!g) m.set(k, (g = { key: k, name: '', orders: [], sum: 0 }));
    g.orders.push(o); if (!g.name && o.customer_name) g.name = o.customer_name; if (o.status !== 'cancelled') g.sum += o.total_idr;
  }
  return [...m.values()].map((g, i) => ({ ...g, label: g.name || t('Pelanggan {0}', i + 1) }));
}
const liveOrders = (b: any) => b.orders.filter((o: any) => o.status !== 'cancelled');
const selected = (b: any) => b.orders.filter((o: any) => sel[o.id]).map((o: any) => o.id);

const paid = (b: any) => (pay[b.id]?.rows || []).reduce((a, r) => a + num(r.amount), 0);
const rest = (b: any) => total(b) - paid(b);
const change = (b: any) => (pay[b.id]?.rows || []).reduce((a, r) => a + (r.method === 'cash' && num(r.tendered) > num(r.amount) ? num(r.tendered) - num(r.amount) : 0), 0);
const tenderedShort = (b: any) => (pay[b.id]?.rows || []).some(r => r.method === 'cash' && r.tendered !== '' && num(r.tendered) < num(r.amount));
const canPay = (b: any) => liveOrders(b).length > 0 && total(b) > 0 && rest(b) === 0 && !tenderedShort(b) && !busyBill.value;

async function load() {
  const tid = S.tid, sc = scope.value;
  const { data, error } = await sb.rpc('list_bills', { p_tenant: tid, p_scope: sc });
  if (tid !== S.tid || sc !== scope.value) return;
  if (error) { loaded.value = true; return toast(error.message); }
  bills.value = data || []; loaded.value = true;
  for (const b of bills.value) {
    if (b.status !== 'open') continue;
    const st = (pay[b.id] ??= { rows: [{ method: 'cash', amount: total(b), tendered: '' }], touched: false });
    if (!st.touched) st.rows[0].amount = total(b);
    if (!discTouched[b.id]) disc[b.id] = b.discount_idr || 0;
  }
}
let timer: any, busy = false;
async function poll() { if (busy || document.visibilityState !== 'visible') return; busy = true; await load(); busy = false; }
onMounted(() => { load(); timer = setInterval(poll, 5000); }); onUnmounted(() => clearInterval(timer));
function setScope(s: 'open' | 'closed') { scope.value = s; bills.value = []; loaded.value = false; load(); }

/** Setelah gabung/pisah/urungkan, isian pembayaran lama tidak berlaku lagi (total berubah). */
const resetState = () => { for (const o of [pay, discTouched, sel] as any[]) Object.keys(o).forEach(k => delete o[k]); };
async function act(b: any, p: Promise<any>, ok = '', reset = false) {
  busyBill.value = b?.id || 'x'; const { data, error } = await p; busyBill.value = '';
  if (error) { toast(error.message); return null; }
  if (reset) resetState();
  if (ok) toast(ok); await load(); loadBillReqs(); return data ?? true;
}
const touch = (b: any) => { pay[b.id].touched = true; };
function addRow(b: any) { touch(b); const r = rest(b); pay[b.id].rows.push({ method: 'qris', amount: r > 0 ? r : '', tendered: '' }); }
function delRow(b: any, i: number) { touch(b); pay[b.id].rows.splice(i, 1); if (!pay[b.id].rows.length) pay[b.id].rows.push({ method: 'cash', amount: total(b), tendered: '' }); }
function fillRest(b: any, r: Row) { touch(b); r.amount = num(r.amount) + rest(b); }
function onMethod(b: any, r: Row) { touch(b); if (r.method !== 'cash') r.tendered = ''; }
async function doPay(b: any) {
  const rows = pay[b.id].rows.map(r => ({ method: r.method, amount: num(r.amount), tendered: r.method === 'cash' && r.tendered !== '' ? num(r.tendered) : undefined }));
  const res: any = await act(b, sb.rpc('pay_bill', { p_bill: b.id, p_payments: rows }));
  if (res) { delete pay[b.id]; toast(res.change > 0 ? t('Lunas. Kembalian {0}', rp(res.change)) : t('Lunas.')); }
}
async function applyDisc(b: any) { const v = num(disc[b.id]); discTouched[b.id] = false; await act(b, sb.rpc('set_bill_discount', { p_bill: b.id, p_amount: v }), t('Diskon disimpan')); }
async function doSplit(b: any) {
  const ids = selected(b); if (!ids.length) return;
  if (!confirm(t('Pisahkan {0} pesanan ke tagihan baru? Tagihan baru dibayar sendiri.', ids.length))) return;
  ids.forEach((id: string) => delete sel[id]); await act(b, sb.rpc('split_orders', { p_orders: ids }), t('Pesanan dipisahkan'), true);
}
async function doUndo(b: any) { if (!b.undo || !confirm(t('Urungkan: {0}?', b.undo.summary))) return; await act(b, sb.rpc('undo_last', { p_bill: b.id }), t('Tindakan diurungkan'), true); }
async function doVoid(b: any) { const r = prompt(t('Tutup paksa tagihan {0} tanpa pembayaran? Tulis alasan (opsional):', title(b))); if (r === null) return; await act(b, sb.rpc('void_bill', { p_bill: b.id, p_reason: r }), t('Tagihan ditutup')); }
async function doReopen(b: any) { const r = prompt(t('Batalkan pembayaran tagihan {0}? Tulis alasan (opsional):', title(b))); if (r === null) return; await act(b, sb.rpc('reopen_bill', { p_bill: b.id, p_reason: r }), t('Pembayaran dibatalkan, tagihan dibuka lagi')); }

/* ---- gabung meja ---- */
const mdlg = ref<any>(), pick = reactive<Record<string, boolean>>({});
const tableBill = computed(() => { const m: Record<string, any> = {}; for (const b of scope.value === 'open' ? bills.value : []) for (const x of b.tables || []) if (x.id) m[x.id] = b; return m; });
const mergeable = computed(() => S.tables.filter((x: any) => x.is_active));
const nPick = computed(() => Object.keys(pick).filter(k => pick[k]).length);
/** Ringkasan sebelum gabung: tiap meja → tagihan & subtotalnya, plus subtotal gabungan. */
const preview = computed(() => {
  const rows = Object.keys(pick).filter(k => pick[k]).map(id => ({ id, label: S.tables.find((x: any) => x.id === id)?.label, bill: tableBill.value[id] }));
  const uniq = [...new Map(rows.filter(r => r.bill).map(r => [r.bill.id, r.bill])).values()] as any[];
  return { rows, sub: uniq.reduce((a, x) => a + Number(x.figures?.subtotal || 0), 0) };
});
/* ---- gabung tagihan (mis. tagihan hasil pisahan kembali ke tagihan meja) ---- */
const bdlg = ref<any>(), mbSrc = ref<any>(null), mbTarget = ref('');
const mbOptions = computed(() => bills.value.filter((x: any) => x.status === 'open' && x.id !== mbSrc.value?.id));
const otherOpen = (b: any) => bills.value.some((x: any) => x.status === 'open' && x.id !== b.id);
function openMergeBill(b: any) { mbSrc.value = b; mbTarget.value = ''; bdlg.value?.open(); }
async function doMergeBill() {
  if (!mbSrc.value || !mbTarget.value) return;
  const r = await act(mbSrc.value, sb.rpc('merge_bills', { p_target: mbTarget.value, p_sources: [mbSrc.value.id] }), t('Tagihan digabung'), true); if (r) bdlg.value?.close();
}
async function openMerge() {
  if (scope.value !== 'open') setScope('open');
  const { data } = await sb.from('restaurant_tables').select('*').eq('tenant_id', S.tid); if (data) S.tables = data.sort((a: any, b: any) => a.sort - b.sort || (a.created_at || '').localeCompare(b.created_at || ''));
  Object.keys(pick).forEach(k => delete pick[k]); mdlg.value?.open();
}
async function doMerge() {
  const ids = Object.keys(pick).filter(k => pick[k]); if (ids.length < 2) return;
  const r = await act(null, sb.rpc('merge_tables', { p_tenant: S.tid, p_tables: ids }), t('Meja digabung'), true); if (r) mdlg.value?.close();
}
</script>
<template>
  <div>
    <div class="bar row" style="justify-content:space-between">
      <span class="langsw"><button :class="{ on: scope === 'open' }" @click="setScope('open')">{{ t('Terbuka') }}</button><button :class="{ on: scope === 'closed' }" @click="setScope('closed')">{{ t('Lunas / ditutup hari ini') }}</button></span>
      <span class="row" style="gap:.6rem"><button class="btn ghost" @click="openMerge">{{ t('Gabungkan meja') }}</button><span class="hint">{{ t('Diperbarui otomatis tiap 5 detik') }}</span></span></div>

    <div class="bgrid">
      <div v-for="b in bills" :key="b.id" class="bcard" :class="{ req: b.requested_at && b.status === 'open', dim: b.status !== 'open' }">
        <div class="bhead"><b>{{ title(b) }}</b><b>{{ where(b) }}</b><span class="muted">{{ hm(b.opened_at) }}</span>
          <span v-if="b.requested_at && b.status === 'open'" class="paytag">🔔 {{ t('Minta bill') }} {{ hm(b.requested_at) }}</span>
          <span v-if="b.status === 'paid'" class="paytag ok">{{ t('Lunas') }}</span><span v-else-if="b.status === 'void'" class="paytag">{{ t('Ditutup') }}</span></div>
        <p v-if="b.status === 'void' && b.close_reason" class="hint">{{ b.close_reason }}</p>

        <div v-for="g in groups(b)" :key="g.key" class="bgroup">
          <div class="bg-h"><b>{{ g.label }}</b><span>{{ rp(g.sum) }}</span></div>
          <div v-for="o in g.orders" :key="o.id" class="bord" :class="{ off: o.status === 'cancelled' }">
            <label v-if="b.status === 'open' && o.status !== 'cancelled' && liveOrders(b).length > 1" class="chk"><input v-model="sel[o.id]" type="checkbox" /></label>
            <div><span class="muted">#{{ o.order_no }} · {{ o.table_label }} · {{ hm(o.created_at) }} · {{ STATUS()[o.status] }}</span>
              <ul><li v-for="(i, k) in o.items" :key="k">{{ i.qty }} × {{ i.name }}</li></ul><span v-if="o.note" class="hint">📝 {{ o.note }}</span></div>
            <span class="muted">{{ rp(o.total_idr) }}</span>
          </div>
        </div>
        <div v-if="b.status === 'open' && b.undo" class="row"><button class="btn ghost" @click="doUndo(b)">↶ {{ t('Urungkan: {0}', b.undo.summary) }}</button></div>
        <div v-if="b.status === 'open' && selected(b).length" class="row"><button class="btn ghost" @click="doSplit(b)">{{ t('Pisahkan {0} pesanan terpilih', selected(b).length) }}</button></div>

        <div class="bfig">
          <div><span>{{ t('Subtotal') }}</span><span>{{ rp(b.figures.subtotal) }}</span></div>
          <div v-if="b.status === 'open'" class="drow"><span>{{ t('Diskon (Rp)') }}</span>
            <span class="row" style="gap:.3rem"><input v-model="disc[b.id]" type="number" min="0" @input="discTouched[b.id] = true" /><button v-if="discTouched[b.id]" @click="applyDisc(b)">{{ t('Terapkan') }}</button></span></div>
          <div v-else-if="b.figures.discount"><span>{{ t('Diskon') }}</span><span>− {{ rp(b.figures.discount) }}</span></div>
          <div v-if="Number(b.figures.service_pct) > 0"><span>{{ t('Biaya layanan') }} {{ Number(b.figures.service_pct) }}%</span><span>{{ rp(b.figures.service) }}</span></div>
          <div v-if="Number(b.figures.tax_pct) > 0"><span>{{ t('Pajak') }} {{ Number(b.figures.tax_pct) }}%</span><span>{{ rp(b.figures.tax) }}</span></div>
          <div class="btotal"><span>{{ t('Total') }}</span><span>{{ rp(b.figures.total) }}</span></div>
        </div>

        <template v-if="b.status === 'open' && pay[b.id]">
          <div v-for="(r, i) in pay[b.id].rows" :key="i" class="prow">
            <select v-model="r.method" @change="onMethod(b, r)"><option v-for="(v, k) in METHODS()" :key="k" :value="k">{{ v }}</option></select>
            <input v-model="r.amount" type="number" min="0" :placeholder="t('Nominal')" @input="touch(b)" />
            <input v-if="r.method === 'cash'" v-model="r.tendered" type="number" min="0" :placeholder="t('Uang diterima')" @input="touch(b)" />
            <button v-if="rest(b) > 0" type="button" @click="fillRest(b, r)">{{ t('Isi sisa') }}</button>
            <button v-if="pay[b.id].rows.length > 1" type="button" class="danger" @click="delRow(b, i)">✕</button>
          </div>
          <div class="pstat" :class="{ bad: rest(b) !== 0 }">
            <span>{{ rest(b) === 0 ? t('Pas ✔') : rest(b) > 0 ? t('Kurang {0}', rp(rest(b))) : t('Lebih {0}', rp(-rest(b))) }}</span><span v-if="change(b) > 0">{{ t('Kembalian {0}', rp(change(b))) }}</span></div>
          <div class="row" style="gap:.4rem;flex-wrap:wrap">
            <button class="btn vm" :disabled="!canPay(b)" @click="doPay(b)">{{ t('Bayar {0}', rp(total(b))) }}</button>
            <button class="btn ghost" type="button" @click="addRow(b)">{{ t('+ Metode lain') }}</button>
            <button v-if="otherOpen(b)" class="btn ghost" type="button" @click="openMergeBill(b)">{{ t('Gabungkan ke tagihan lain') }}</button>
            <button v-if="can.void()" class="btn ghost danger" type="button" @click="doVoid(b)">{{ t('Tutup paksa') }}</button></div>
        </template>

        <template v-else-if="b.status === 'paid'">
          <ul class="paylist"><li v-for="(p, i) in b.payments" :key="i">{{ METHODS()[p.method] }} · {{ rp(p.amount_idr) }}<template v-if="p.tendered_idr && p.tendered_idr > p.amount_idr"> ({{ t('diterima {0}', rp(p.tendered_idr)) }})</template></li></ul>
          <div v-if="can.void()" class="row"><button class="btn ghost danger" @click="doReopen(b)">{{ t('Batalkan pembayaran') }}</button></div>
        </template>
        <details v-if="b.events?.length" class="bhist"><summary>{{ t('Riwayat tindakan') }} ({{ b.events.length }})</summary>
          <ul><li v-for="e in b.events" :key="e.id" :class="{ off: e.undone }">{{ hm(e.at) }} · {{ e.by || '—' }} · {{ e.summary }}<template v-if="e.undone"> ({{ t('diurungkan') }})</template></li></ul></details>
      </div>
      <p v-if="loaded && !bills.length" class="muted">{{ scope === 'open' ? t('Tidak ada tagihan terbuka.') : t('Belum ada tagihan yang ditutup hari ini.') }}</p>
    </div>

    <Modal ref="mdlg"><form method="dialog" class="dlg" @submit.prevent="doMerge">
      <h3>{{ t('Gabungkan meja') }}</h3><p class="hint">{{ t('Pilih 2 meja atau lebih. Tagihannya dilebur jadi satu; pesanan baru dari meja mana pun ikut masuk ke tagihan ini.') }}</p>
      <div class="mpick"><label v-for="tb in mergeable" :key="tb.id"><input v-model="pick[tb.id]" type="checkbox" /> <b>{{ tb.label }}</b>
        <span class="muted">{{ tableBill[tb.id] ? t('tagihan {0}', title(tableBill[tb.id])) : t('kosong') }}</span></label></div>
      <div v-if="nPick >= 2" class="mprev"><b>{{ t('Ringkasan') }}</b>
        <div v-for="r in preview.rows" :key="r.id">{{ r.label }} → {{ r.bill ? `${title(r.bill)} · ${rp(r.bill.figures.subtotal)}` : t('kosong') }}</div>
        <div>{{ t('Hasil: satu tagihan, subtotal {0}', rp(preview.sub)) }}</div></div>
      <div class="row" style="gap:.5rem;margin-top:1rem"><button type="submit" class="btn vm" :disabled="nPick < 2">{{ t('Gabungkan {0} meja', nPick) }}</button><button type="button" class="btn ghost" @click="mdlg.close()">{{ t('Batal') }}</button></div>
    </form></Modal>

    <Modal ref="bdlg"><form method="dialog" class="dlg" @submit.prevent="doMergeBill">
      <h3>{{ t('Gabungkan ke tagihan lain') }}</h3>
      <p class="hint">{{ mbSrc ? t('Semua pesanan {0} ({1}) dipindahkan ke tagihan yang Anda pilih. Bisa diurungkan sebelum dibayar.', title(mbSrc), where(mbSrc)) : '' }}</p>
      <div class="mpick"><label v-for="x in mbOptions" :key="x.id"><input v-model="mbTarget" type="radio" :value="x.id" /> <b>{{ title(x) }}</b> {{ where(x) }} <span class="muted">{{ rp(x.figures.subtotal) }}</span></label></div>
      <div class="row" style="gap:.5rem;margin-top:1rem"><button type="submit" class="btn vm" :disabled="!mbTarget">{{ t('Gabungkan') }}</button><button type="button" class="btn ghost" @click="bdlg.close()">{{ t('Batal') }}</button></div>
    </form></Modal>
  </div>
</template>
