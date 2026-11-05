<script setup lang="ts">
import { computed, ref } from 'vue';
import { t } from '../lib/i18n';
import { purgeApi } from '../lib/api';
import { S, boot } from '../store';
import Modal from './Modal.vue';

/** Zona berbahaya — hanya Super Admin (server dan database menolak yang lain). Dua pilihan: satu tenant, atau semua tenant. */
const m = ref<any>();
type Step = 'choose' | 'review' | 'running' | 'done';
const step = ref<Step>('choose'), scope = ref<'tenant' | 'all'>('tenant'), pick = ref(''), pv = ref<any>(null);
const typed = ref(''), delUsers = ref(false), delImages = ref(true), msg = ref(''), prog = ref(''), busy = ref(false);
const out = ref<any>(null), prefixes = ref<string[]>([]), imgDel = ref(0), imgFail = ref(0), imgErr = ref('');

function open() {
  step.value = 'choose'; scope.value = 'tenant'; pick.value = S.tid; pv.value = null; typed.value = ''; delUsers.value = false; delImages.value = true;
  msg.value = prog.value = imgErr.value = ''; out.value = null; imgDel.value = imgFail.value = 0; busy.value = false; m.value.open();
}
defineExpose({ open });

const body = () => ({ scope: scope.value, tenant_id: scope.value === 'tenant' ? pick.value : undefined });
const totals = computed(() => (pv.value?.tenants || []).reduce((a: any, x: any) => ({ orders: a.orders + x.orders, menu: a.menu + x.menu_items, cats: a.cats + x.categories, tables: a.tables + x.tables, members: a.members + x.members }), { orders: 0, menu: 0, cats: 0, tables: 0, members: 0 }));
const ready = computed(() => !!pv.value && typed.value.trim() === pv.value.confirm && !busy.value);
const imgText = computed(() => { const i = pv.value?.images; return !i?.configured ? '' : i.count == null ? t('jumlah foto tidak diketahui') : (i.more ? '≥ ' : '') + i.count + ' ' + t('foto'); });

async function review() {
  msg.value = ''; busy.value = true;
  try { pv.value = await purgeApi({ action: 'preview', ...body() }); step.value = 'review'; typed.value = ''; delImages.value = !!pv.value.images?.configured; }
  catch (e: any) { msg.value = e.message; } finally { busy.value = false; }
}
async function cleanImages(list: string[]) {
  imgErr.value = '';
  try {
    for (const p of list) {
      let cursor: string | null = null, guard = 0;
      do {
        const r: any = await purgeApi({ action: 'images', prefix: p, cursor });
        imgDel.value += r.deleted || 0; imgFail.value += r.failed || 0; cursor = r.cursor || null;
        prog.value = t('Menghapus foto… {0} terhapus', imgDel.value);
      } while (cursor && ++guard < 2000);
    }
    prog.value = '';
  } catch (e: any) { imgErr.value = e.message; prog.value = ''; }
}
async function run() {
  if (!ready.value) return;
  msg.value = ''; busy.value = true; step.value = 'running'; prog.value = t('Menghapus data…');
  try {
    const r = await purgeApi({ action: 'delete', ...body(), confirm: typed.value.trim(), delete_users: delUsers.value });
    out.value = r.result; prefixes.value = r.prefixes || [];
    if (delImages.value && pv.value?.images?.configured) await cleanImages(prefixes.value);
    step.value = 'done';
  } catch (e: any) { msg.value = e.message; step.value = 'review'; }   // gagal di database = tidak ada yang terhapus (satu transaksi)
  finally { busy.value = false; prog.value = ''; }
}
async function retryImages() { busy.value = true; await cleanImages(prefixes.value); busy.value = false; }
const onClose = () => { if (step.value === 'done') boot(); };   // muat ulang daftar restoran setelah selesai
const onCancel = (ev: Event) => { if (step.value === 'running') ev.preventDefault(); };   // Esc diabaikan saat proses berjalan
</script>
<template>
  <div class="panel dz"><h3>{{ t('Hapus data tenant') }} <small class="muted">{{ t('(hanya Super Admin)') }}</small></h3>
    <p class="hint">{{ t('Menghapus restoran beserta semua data turunannya: menu, kategori, meja, pesanan, banner, teks & foto website, domain, langganan, dan foto di penyimpanan. Tidak bisa dibatalkan.') }}</p>
    <div class="row"><button class="btn vm" type="button" @click="open">{{ t('Hapus data tenant…') }}</button></div>
    <Modal ref="m" @close="onClose" @cancel="onCancel"><div class="purge">
      <h3>{{ t('Hapus data tenant') }}</h3>

      <template v-if="step === 'choose'">
        <fieldset><legend>{{ t('Yang dihapus') }}</legend>
          <label class="rad"><input v-model="scope" type="radio" value="tenant" /> {{ t('Satu tenant tertentu') }}</label>
          <select v-if="scope === 'tenant'" v-model="pick"><option v-for="x in S.tenants" :key="x.id" :value="x.id">{{ x.slug }}</option></select>
          <label class="rad"><input v-model="scope" type="radio" value="all" /> {{ t('SEMUA tenant ({0} restoran)', S.tenants.length) }}</label></fieldset>
        <p class="err">{{ msg }}</p>
        <div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button type="button" class="btn" :disabled="busy || (scope === 'tenant' && !pick)" @click="review">{{ busy ? t('Memeriksa…') : t('Lihat yang akan dihapus') }}</button></div>
      </template>

      <template v-else-if="step === 'review' && pv">
        <p class="warn">{{ scope === 'all' ? t('Anda akan menghapus SEMUA tenant.') : t('Anda akan menghapus tenant {0}.', pv.tenants[0]?.slug) }} {{ t('Tidak bisa dibatalkan.') }}</p>
        <div class="tscroll"><table class="tbl"><thead><tr><th>{{ t('Restoran') }}</th><th>{{ t('Pesanan') }}</th><th>{{ t('Menu') }}</th><th>{{ t('Kategori') }}</th><th>{{ t('Meja') }}</th><th>{{ t('Akun') }}</th></tr></thead><tbody>
          <tr v-for="x in pv.tenants" :key="x.id"><td>{{ x.slug }}</td><td>{{ x.orders }}</td><td>{{ x.menu_items }}</td><td>{{ x.categories }}</td><td>{{ x.tables }}</td><td>{{ x.members }}</td></tr>
          <tr v-if="pv.tenants.length > 1"><td><b>{{ t('Total') }}</b></td><td><b>{{ totals.orders }}</b></td><td><b>{{ totals.menu }}</b></td><td><b>{{ totals.cats }}</b></td><td><b>{{ totals.tables }}</b></td><td><b>{{ totals.members }}</b></td></tr></tbody></table></div>
        <p class="hint">{{ t('Ikut terhapus: terjemahan, teks & foto website, banner, domain, langganan, pemakaian AI.') }}</p>

        <label class="rad"><input v-model="delImages" type="checkbox" :disabled="!pv.images?.configured" /> {{ t('Hapus juga foto di penyimpanan (R2)') }} <span v-if="imgText" class="muted">— {{ imgText }}</span></label>
        <p v-if="!pv.images?.configured" class="hint">{{ t('Penyimpanan foto (R2) belum dikonfigurasi di server, jadi foto tidak bisa dihapus dari sini.') }}</p>
        <label v-if="pv.users.length" class="rad"><input v-model="delUsers" type="checkbox" /> {{ scope === 'all' ? t('Hapus juga semua akun login selain Super Admin ({0})', pv.users.length) : t('Hapus juga akun login yang hanya terkait tenant ini ({0})', pv.users.length) }}</label>
        <p v-if="pv.users.length" class="hint">{{ pv.users.slice(0, 8).join(', ') }}{{ pv.users.length > 8 ? ' ' + t('dan {0} lainnya', pv.users.length - 8) : '' }}. {{ t('Akun Super Admin dan akun Anda tidak pernah ikut terhapus.') }}</p>

        <label>{{ t('Untuk melanjutkan, ketik {0}', pv.confirm) }}<input v-model="typed" autocomplete="off" autocapitalize="off" spellcheck="false" :placeholder="pv.confirm" /></label>
        <p class="err">{{ msg }}</p>
        <div class="row"><button type="button" class="btn ghost" @click="step = 'choose'">{{ t('Kembali') }}</button><button type="button" class="btn vm" :disabled="!ready" @click="run">{{ scope === 'all' ? t('Hapus SEMUA tenant') : t('Hapus tenant ini') }}</button></div>
      </template>

      <template v-else-if="step === 'running'"><p class="muted">{{ prog }}</p><p class="hint">{{ t('Jangan tutup halaman ini sampai selesai.') }}</p></template>

      <template v-else-if="step === 'done'">
        <p class="okmsg">{{ t('Selesai.') }} {{ t('{0} restoran, {1} pesanan, {2} menu, {3} akun dihapus.', out?.tenants ?? 0, out?.orders ?? 0, out?.menu_items ?? 0, out?.users ?? 0) }}</p>
        <p v-if="delImages && !imgErr" class="muted">{{ t('{0} foto dihapus.', imgDel) }}<span v-if="imgFail"> {{ t('{0} foto gagal dihapus.', imgFail) }}</span></p>
        <template v-if="imgErr"><p class="err">{{ t('Data sudah terhapus, tetapi penghapusan foto berhenti: {0}', imgErr) }}</p>
          <div class="row"><button type="button" class="btn ghost" :disabled="busy" @click="retryImages">{{ busy ? prog : t('Ulangi hapus foto') }}</button></div></template>
        <div class="row"><button type="button" class="btn" :disabled="busy" @click="m.close()">{{ t('Tutup') }}</button></div>
      </template>
    </div></Modal>
  </div>
</template>
