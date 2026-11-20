<script setup lang="ts">
import { nextTick, ref, watch } from 'vue';
import { t } from '../lib/i18n';
import { dlg, settleDialog } from '../lib/dialog';
/** Satu-satunya tempat dialog konfirmasi/isian dirender (lihat lib/dialog.ts). Memakai <dialog> sebagai lapisan atas: fokus terkunci, tombol Esc, dan latar belakang tidak bisa disentuh. */
const d = ref<HTMLDialogElement>(), field = ref<HTMLInputElement>(), okBtn = ref<HTMLButtonElement>(), noBtn = ref<HTMLButtonElement>();
watch(() => dlg.open, async open => {
  if (open) { if (!d.value?.open) d.value?.showModal(); await nextTick(); (dlg.kind === 'prompt' ? field.value : dlg.danger ? noBtn.value : okBtn.value)?.focus(); }
  else if (d.value?.open) d.value.close();
});
const onBackdrop = (e: MouseEvent) => { if (e.target === d.value) settleDialog(false); };
</script>
<template>
  <dialog ref="d" class="appdlg" :class="{ danger: dlg.danger }" aria-labelledby="appdlg-t" aria-describedby="appdlg-m" @cancel.prevent="settleDialog(false)" @click="onBackdrop">
    <form @submit.prevent="settleDialog(true)">
      <h3 id="appdlg-t">{{ dlg.title || t('Konfirmasi') }}</h3>
      <p id="appdlg-m" class="appdlg-m">{{ dlg.message }}</p>
      <input v-if="dlg.kind === 'prompt'" ref="field" v-model="dlg.input" class="appdlg-in" maxlength="200" :placeholder="dlg.placeholder" autocomplete="off" />
      <div class="appdlg-act">
        <button ref="noBtn" type="button" class="btn ghost" @click="settleDialog(false)">{{ dlg.cancel || t('Batal') }}</button>
        <button ref="okBtn" type="submit" class="btn" :class="dlg.danger ? 'danger' : 'vm'">{{ dlg.ok || t('Ya, lanjutkan') }}</button>
      </div>
    </form>
  </dialog>
</template>
