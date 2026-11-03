<script setup lang="ts">
import { onMounted, onBeforeUnmount, ref } from 'vue';
import { S, toastMsg, qrList, watchAuth } from './store';
import { t, applyLang, lang } from './lib/i18n';
import LoginBox from './components/LoginBox.vue';
import SignupBox from './components/SignupBox.vue';
import RecoverBox from './components/RecoverBox.vue';
import Shell from './components/Shell.vue';
import QrDialog from './components/QrDialog.vue';
// Pendaftaran restoran baru: admin.<domain>/#daftar (bisa ditautkan dari halaman pemasaran).
const signup = ref(location.hash === '#daftar');
const onHash = () => (signup.value = location.hash === '#daftar');
const backToLogin = () => { signup.value = false; history.replaceState(null, '', location.pathname); };
onMounted(() => { applyLang(lang.value); watchAuth(); addEventListener('hashchange', onHash); });
onBeforeUnmount(() => removeEventListener('hashchange', onHash));
</script>
<template>
  <p v-if="S.view === 'boot'" class="muted boot">{{ t('Memuat…') }}</p>
  <RecoverBox v-else-if="S.view === 'recover'" />
  <SignupBox v-else-if="S.view === 'login' && signup" @back="backToLogin" />
  <LoginBox v-else-if="S.view === 'login'" />
  <Shell v-else />
  <QrDialog v-if="qrList" />
  <div id="toast" :class="{ show: !!toastMsg }">{{ toastMsg }}</div>
</template>
