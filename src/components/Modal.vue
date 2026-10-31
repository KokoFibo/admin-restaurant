<script setup lang="ts">
import { ref } from 'vue';
const d = ref<HTMLDialogElement>();
defineExpose({ open: () => d.value?.showModal(), close: () => d.value?.close() });
</script>
<template><dialog ref="d"><slot /></dialog></template>
