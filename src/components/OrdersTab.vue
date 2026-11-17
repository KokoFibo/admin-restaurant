<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { t, rp } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { S, can, role, toast, billReqs, loadOnlinePending } from '../store';
const orders = ref<any[]>([]), items = ref<any[]>([]), phones = ref<Record<string, string>>({}), filter = ref<'active' | 'all'>('active');
const LIVE = ['new', 'preparing', 'ready'], NEXT: Record<string, string> = { new: 'preparing', preparing: 'ready', ready: 'done' };
const STATUS = () => ({ pending: t('Menunggu konfirmasi'), new: t('Baru'), preparing: t('Diproses'), ready: t('Siap'), done: t('Selesai'), cancelled: t('Batal'), rejected: t('Ditolak'), expired: t('Kedaluwarsa') } as Record<string, string>);
const PAY = () => ({ cash: t('Tunai'), card: t('Kartu'), qris: 'QRIS', other: t('Lainnya') } as Record<string, string>);
async function loadOrders() {
  const tid = S.tid, since = new Date(Date.now() - 24 * 3600e3).toISOString();
  const o = await sb.from('orders').select('*').eq('tenant_id', tid).gte('created_at', since).order('created_at', { ascending: true }).limit(300);
  const ids = (o.data || []).map((x: any) => x.id), it = ids.length ? await sb.from('order_items').select('*').in('order_id', ids) : { data: [] };
  // nomor WhatsApp pelanggan online: hanya Owner/Manager/Cashier yang boleh membacanya (diputuskan database)
  const online = (o.data || []).filter((x: any) => x.source === 'online').map((x: any) => x.id);
  const ct = can.pay() && online.length ? await sb.from('order_contacts').select('order_id,phone').in('order_id', online) : { data: [] };
  if (tid !== S.tid) return; orders.value = o.data || []; items.value = it.data || []; phones.value = Object.fromEntries((ct.data || []).map((c: any) => [c.order_id, c.phone]));
}
const sig = () => JSON.stringify(orders.value.map(o => [o.id, o.status, o.payment_status, o.pay_claimed_at]));
const pendingList = computed(() => orders.value.filter(o => o.status === 'pending').sort((a, b) => a.created_at.localeCompare(b.created_at)));
const list = computed(() => orders.value.filter(o => o.status !== 'pending' && (filter.value === 'all' || LIVE.includes(o.status))).sort((a, b) => (filter.value === 'all' ? b.created_at.localeCompare(a.created_at) : a.created_at.localeCompare(b.created_at))));
const nActive = computed(() => orders.value.filter(o => LIVE.includes(o.status)).length);
const itemsOf = (id: string) => items.value.filter(i => i.order_id === id);
const nextLabel = (st: string) => ({ new: t('Proses'), preparing: t('Siap'), ready: t('Selesai') } as any)[st];
const canNext = (o: any) => NEXT[o.status] && (can.pay() || (role() === 'kitchen' && ['new', 'preparing'].includes(o.status)) || (role() === 'service' && o.status === 'ready'));
const isOnline = (o: any) => o.source === 'online';
const totalOf = (o: any) => (o.status === 'pending' && o.quote?.total != null ? Number(o.quote.total) : o.total_idr);
const brand = computed(() => S.tenTr.find((x: any) => x.lang === S.TL[0])?.brand_name || S.T?.slug || '');
async function refresh() { await loadOrders(); loadOnlinePending(); }
async function act(p: Promise<any>) { const { error } = await p; if (error) { toast(error.message); await refresh(); return; } await refresh(); }
const status = (o: any, s: string) => act(sb.rpc('set_order_status', { p_order: o.id, p_status: s }));
const cancel = (o: any) => confirm(t('Batalkan pesanan #{0}?', o.order_no)) && status(o, 'cancelled');
const accept = (o: any) => act(sb.rpc('accept_online_order', { p_order: o.id }));
const acceptPaid = (o: any) => confirm(t('Pembayaran QRIS {0} sudah masuk di aplikasi merchant Anda? Tagihan akan ditandai lunas dan pesanan masuk dapur.', rp(totalOf(o)))) && act(sb.rpc('accept_online_prepaid', { p_order: o.id }));
function reject(o: any) { const r = prompt(t('Tolak pesanan #{0}? Tulis alasan untuk pelanggan (opsional):', o.order_no)); if (r === null) return; act(sb.rpc('reject_online_order', { p_order: o.id, p_reason: r })); }
/** Buka WhatsApp dengan pesan terisi (nomor dari pesanan; tanpa API, staf menekan Kirim sendiri). */
function wa(o: any) {
  const ph = phones.value[o.id]; if (!ph) return toast(t('Nomor WhatsApp pelanggan tidak tersedia (dihapus otomatis setelah 30 hari).'));
  const msg = t('Halo {0}, pesanan #{1} di {2} sudah siap diambil. Terima kasih!', o.customer_name || '', o.order_no, brand.value);
  window.open(`https://wa.me/${ph}?text=${encodeURIComponent(msg)}`, '_blank', 'noopener');
}
const waAvailable = (o: any) => can.pay() && isOnline(o);
const mins = (o: any) => Math.max(0, Math.floor((Date.now() - new Date(o.created_at).getTime()) / 60000));
let timer: any, busy = false;
async function poll() {
  if (busy || document.visibilityState !== 'visible') return;
  busy = true; const prev = new Set(orders.value.map(o => o.id)), before = sig(); await loadOrders(); busy = false;
  if (sig() !== before) { const fresh = orders.value.filter(o => !prev.has(o.id) && o.status !== 'pending'); if (fresh.length && prev.size) toast(t('Pesanan baru: {0}', fresh.map(o => `#${o.order_no} ${o.table_label}`).join(', '))); }
}
onMounted(() => { loadOrders(); timer = setInterval(poll, 5000); }); onUnmounted(() => clearInterval(timer));
</script>
<template>
  <div>
    <div class="bar row" style="justify-content:space-between">
      <span class="langsw"><button :class="{ on: filter === 'active' }" @click="filter = 'active'">{{ t('Aktif') }} ({{ nActive }})</button><button :class="{ on: filter === 'all' }" @click="filter = 'all'">{{ t('Semua (24 jam)') }}</button></span>
      <span class="hint">{{ t('Diperbarui otomatis tiap 5 detik') }}</span></div>
    <p v-if="role() === 'service' && billReqs.length" class="billbell">🔔 {{ t('Minta bill') }}: <b>{{ billReqs.map((x: any) => x.label).join(', ') }}</b></p>
    <p v-if="can.pay()" class="hint">{{ t('Pembayaran dicatat di tab Tagihan.') }}</p>

    <section v-if="can.pay() && pendingList.length" class="osec pend" aria-live="polite">
      <h3>🔴 {{ t('Menunggu konfirmasi') }} ({{ pendingList.length }})</h3>
      <p class="hint">{{ t('Pesanan online baru belum masuk dapur sampai Anda menerimanya. Tidak dikonfirmasi dalam 15 menit = kedaluwarsa otomatis.') }}</p>
      <div class="ogrid">
        <div v-for="o in pendingList" :key="o.id" class="ocard st-pending">
          <div class="ohead"><b>#{{ o.order_no }}</b><span class="rolebadge">{{ t('Online') }}</span><b>{{ o.customer_name }}</b>
            <span class="muted">{{ new Date(o.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }} · {{ t('{0} menit lalu', mins(o)) }}</span></div>
          <div class="ohead"><span class="paytag">{{ o.pickup_by === 'courier' ? t('Diambil kurir') : t('Diambil pelanggan') }}</span>
            <span v-if="o.pay_plan === 'prepay_qris'" class="paytag" :class="{ ok: o.pay_claimed_at }">{{ o.pay_claimed_at ? t('Bayar di muka QRIS: pelanggan menekan "Sudah bayar"') : t('Bayar di muka QRIS: belum ditandai bayar') }}</span>
            <span v-else class="paytag">{{ t('Bayar di tempat') }}</span></div>
          <ul><li v-for="i in itemsOf(o.id)" :key="i.id">{{ i.qty }} × {{ i.name_snapshot }}</li></ul>
          <p v-if="o.note" class="hint">📝 {{ o.note }}</p>
          <div class="oft"><b>{{ rp(totalOf(o)) }}</b>
            <span class="row" style="gap:.35rem">
              <button v-if="o.pay_plan === 'prepay_qris'" @click="acceptPaid(o)">{{ t('Pembayaran diterima') }}</button>
              <button v-else @click="accept(o)">{{ t('Terima') }}</button>
              <button class="danger" @click="reject(o)">{{ t('Tolak') }}</button></span></div>
        </div>
      </div>
    </section>

    <div class="ogrid">
      <div v-for="o in list" :key="o.id" class="ocard" :class="'st-' + o.status">
        <div class="ohead"><b>#{{ o.order_no }}</b><span class="rolebadge">{{ STATUS()[o.status] }}</span><b>{{ isOnline(o) ? t('Online') : o.table_label }}</b>
          <span class="muted">{{ new Date(o.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }}</span>
          <span v-if="can.pay() && o.status !== 'rejected' && o.status !== 'expired'" class="paytag" :class="{ ok: o.payment_status === 'paid' }">{{ o.payment_status === 'paid' ? `${t('Dibayar')} · ${PAY()[o.payment_method] || ''}` : t('Belum dibayar') }}</span></div>
        <span v-if="o.customer_name" class="muted">{{ o.customer_name }}<template v-if="isOnline(o)"> · {{ o.pickup_by === 'courier' ? t('Diambil kurir') : t('Diambil pelanggan') }}</template></span>
        <ul><li v-for="i in itemsOf(o.id)" :key="i.id">{{ i.qty }} × {{ i.name_snapshot }}</li></ul>
        <p v-if="o.note" class="hint">📝 {{ o.note }}</p>
        <p v-if="o.status === 'rejected' && o.reject_reason" class="hint">{{ o.reject_reason }}</p>
        <div class="oft"><b v-if="can.pay()">{{ rp(o.total_idr) }}</b><span v-else />
          <span class="row" style="gap:.35rem;flex-wrap:wrap">
            <button v-if="o.status === 'ready' && waAvailable(o)" @click="wa(o)">💬 {{ t('Kabari via WhatsApp') }}</button>
            <button v-if="canNext(o)" @click="status(o, NEXT[o.status])">{{ nextLabel(o.status) }}</button>
            <button v-if="can.pay() && LIVE.includes(o.status)" class="danger" @click="cancel(o)">{{ t('Batal') }}</button>
            <button v-if="can.pay() && (o.status === 'done' || (o.status === 'cancelled' && !isOnline(o)))" @click="status(o, 'new')">{{ t('Buka lagi') }}</button>
</span></div>
      </div>
      <p v-if="!list.length && !pendingList.length" class="muted">{{ t('Belum ada pesanan.') }}</p>
    </div>
  </div>
</template>
