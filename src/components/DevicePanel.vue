<script setup lang="ts">
import { t } from '../lib/i18n';
import { wakeOn, wakeActive, wakeSupported, setWake } from '../lib/wakelock';
import { soundOn, setSound } from '../lib/alert';
import { can } from '../store';
</script>
<template>
  <form class="panel" @submit.prevent>
    <h3>{{ t('Perangkat ini') }}</h3>
    <p class="hint">{{ t('Pengaturan di bawah hanya berlaku di perangkat yang sedang Anda pakai, bukan untuk akun atau restoran.') }}</p>
    <label class="tgl"><input type="checkbox" :checked="wakeOn" :disabled="!wakeSupported" @change="setWake(($event.target as HTMLInputElement).checked)" />
      <span>{{ t('Jaga layar tetap menyala') }}<br /><span class="hint">{{ t('Berguna untuk tablet dapur dan kasir agar layar tidak mati saat sibuk. Baterai lebih cepat habis, jadi sebaiknya tablet tersambung ke pengisi daya.') }}</span></span></label>
    <label v-if="can.pay()" class="tgl"><input type="checkbox" :checked="soundOn" @change="setSound(($event.target as HTMLInputElement).checked)" />
      <span>{{ t('Bunyi pesanan online baru') }}<br /><span class="hint">{{ t('Berbunyi berulang selama ada pesanan online yang menunggu konfirmasi, hanya saat halaman admin terbuka. Bunyi tidak akan terdengar bila layar terkunci atau aplikasi ditutup.') }}</span></span></label>
    <p v-if="!wakeSupported" class="hint">{{ t('Browser ini tidak mendukung fitur ini.') }}</p>
    <p v-else-if="wakeOn" class="hint" role="status">{{ wakeActive ? t('Aktif: layar tidak akan mati selama halaman ini terbuka.') : t('Belum aktif. Akan aktif saat halaman terbuka dan terlihat.') }}</p>
  </form>
</template>
