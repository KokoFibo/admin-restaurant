<script setup lang="ts">
import { onMounted } from 'vue';
import { S, toastMsg, qrList, watchAuth } from './store';
import { t, applyLang, lang } from './lib/i18n';
import LoginBox from './components/LoginBox.vue';
import RecoverBox from './components/RecoverBox.vue';
import Shell from './components/Shell.vue';
import QrDialog from './components/QrDialog.vue';
onMounted(() => { applyLang(lang.value); watchAuth(); });
</script>
<template>
  <p v-if="S.view === 'boot'" class="muted boot">{{ t('Memuat…') }}</p>
  <RecoverBox v-else-if="S.view === 'recover'" />
  <LoginBox v-else-if="S.view === 'login'" />
  <Shell v-else />
  <QrDialog v-if="qrList" />
  <div id="toast" :class="{ show: !!toastMsg }">{{ toastMsg }}</div>
</template>
