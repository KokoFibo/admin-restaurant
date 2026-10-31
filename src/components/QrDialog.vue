<script setup lang="ts">
import { onMounted, ref } from 'vue';
import QRCode from 'qrcode';
import { t } from '../lib/i18n';
import { qrList, siteBase } from '../store';
const d = ref<HTMLDialogElement>(), cards = ref<{ label: string; url: string; img: string }[]>([]), ready = ref(false);
onMounted(async () => {
  d.value!.showModal();
  cards.value = await Promise.all((qrList.value || []).map(async (x: any) => { const url = `${siteBase()}/order?meja=${x.token}`; return { label: x.label, url, img: await QRCode.toDataURL(url, { width: 480, margin: 1 }) }; }));
  ready.value = true;
});
const close = () => { qrList.value = null; };
const print = () => { document.body.classList.add('printing'); window.print(); };
addEventListener('afterprint', () => document.body.classList.remove('printing'));
</script>
<template>
  <dialog id="qdlg" ref="d" @close="close">
    <p v-if="!ready" class="muted">{{ t('Membuat QR…') }}</p>
    <div v-else>
      <div class="row noprint" style="justify-content:space-between"><h3>{{ t('QR meja') }}</h3><span><button class="btn" @click="print">{{ t('Cetak') }}</button> <button class="btn ghost" @click="d!.close()">{{ t('Tutup') }}</button></span></div>
      <div class="qgrid"><div v-for="c in cards" :key="c.url" class="qcard"><b>{{ c.label }}</b><img :alt="'QR ' + c.label" :src="c.img" /><small>{{ c.url }}</small></div></div>
      <p v-if="!cards.length" class="muted">{{ t('Belum ada meja aktif.') }}</p>
    </div>
  </dialog>
</template>
