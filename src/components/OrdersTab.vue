<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { t, rp } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { S, can, role, toast, billReqs } from '../store';
const orders = ref<any[]>([]), items = ref<any[]>([]), filter = ref<'active' | 'all'>('active');
const LIVE = ['new', 'preparing', 'ready'], NEXT: Record<string, string> = { new: 'preparing', preparing: 'ready', ready: 'done' };
const STATUS = () => ({ new: t('Baru'), preparing: t('Diproses'), ready: t('Siap'), done: t('Selesai'), cancelled: t('Batal') } as Record<string, string>);
const PAY = () => ({ cash: t('Tunai'), card: t('Kartu'), qris: 'QRIS', other: t('Lainnya') } as Record<string, string>);
async function loadOrders() {
  const tid = S.tid, since = new Date(Date.now() - 24 * 3600e3).toISOString();
  const o = await sb.from('orders').select('*').eq('tenant_id', tid).gte('created_at', since).order('created_at', { ascending: true }).limit(300);
  const ids = (o.data || []).map((x: any) => x.id), it = ids.length ? await sb.from('order_items').select('*').in('order_id', ids) : { data: [] };
  if (tid !== S.tid) return; orders.value = o.data || []; items.value = it.data || [];
}
const sig = () => JSON.stringify(orders.value.map(o => [o.id, o.status, o.payment_status]));
const list = computed(() => orders.value.filter(o => filter.value === 'all' || LIVE.includes(o.status)).sort((a, b) => (filter.value === 'all' ? b.created_at.localeCompare(a.created_at) : a.created_at.localeCompare(b.created_at))));
const nActive = computed(() => orders.value.filter(o => LIVE.includes(o.status)).length);
const itemsOf = (id: string) => items.value.filter(i => i.order_id === id);
const nextLabel = (st: string) => ({ new: t('Proses'), preparing: t('Siap'), ready: t('Selesai') } as any)[st];
const canNext = (o: any) => NEXT[o.status] && (can.pay() || (role() === 'kitchen' && ['new', 'preparing'].includes(o.status)) || (role() === 'service' && o.status === 'ready'));
async function act(p: Promise<any>) { const { error } = await p; if (error) return toast(error.message); await loadOrders(); }
const status = (o: any, s: string) => act(sb.rpc('set_order_status', { p_order: o.id, p_status: s }));
const cancel = (o: any) => confirm(t('Batalkan pesanan #{0}?', o.order_no)) && status(o, 'cancelled');
let timer: any, busy = false;
async function poll() {
  if (busy || document.visibilityState !== 'visible') return;
  busy = true; const prev = new Set(orders.value.map(o => o.id)), before = sig(); await loadOrders(); busy = false;
  if (sig() !== before) { const fresh = orders.value.filter(o => !prev.has(o.id)); if (fresh.length && prev.size) toast(t('Pesanan baru: {0}', fresh.map(o => `#${o.order_no} ${o.table_label}`).join(', '))); }
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
    <div class="ogrid">
      <div v-for="o in list" :key="o.id" class="ocard" :class="'st-' + o.status">
        <div class="ohead"><b>#{{ o.order_no }}</b><span class="rolebadge">{{ STATUS()[o.status] }}</span><b>{{ o.table_label }}</b>
          <span class="muted">{{ new Date(o.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }}</span>
          <span v-if="can.pay()" class="paytag" :class="{ ok: o.payment_status === 'paid' }">{{ o.payment_status === 'paid' ? `${t('Dibayar')} · ${PAY()[o.payment_method] || ''}` : t('Belum dibayar') }}</span></div>
        <span v-if="o.customer_name" class="muted">{{ o.customer_name }}</span>
        <ul><li v-for="i in itemsOf(o.id)" :key="i.id">{{ i.qty }} × {{ i.name_snapshot }}</li></ul>
        <p v-if="o.note" class="hint">📝 {{ o.note }}</p>
        <div class="oft"><b v-if="can.pay()">{{ rp(o.total_idr) }}</b><span v-else />
          <span class="row" style="gap:.35rem">
            <button v-if="canNext(o)" @click="status(o, NEXT[o.status])">{{ nextLabel(o.status) }}</button>
            <button v-if="can.pay() && !['cancelled', 'done'].includes(o.status)" class="danger" @click="cancel(o)">{{ t('Batal') }}</button>
            <button v-if="can.pay() && ['cancelled', 'done'].includes(o.status)" @click="status(o, 'new')">{{ t('Buka lagi') }}</button>
</span></div>
      </div>
      <p v-if="!list.length" class="muted">{{ t('Belum ada pesanan.') }}</p>
    </div>
  </div>
</template>
