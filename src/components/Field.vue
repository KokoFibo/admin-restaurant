<script setup lang="ts">
import { computed } from 'vue';
const props = defineProps<{ label: string; max: number; rows?: number; modelValue?: string }>();
defineEmits(['update:modelValue']);
const n = computed(() => [...(props.modelValue || '')].length);
</script>
<template>
  <label>{{ label }} <span class="cnt" :class="{ bad: n >= max }">{{ n }}/{{ max }}</span>
    <textarea v-if="(rows || 1) > 1" :rows="rows" :maxlength="max" :value="modelValue" @input="$emit('update:modelValue', ($event.target as any).value)" />
    <input v-else :maxlength="max" :value="modelValue" @input="$emit('update:modelValue', ($event.target as any).value)" />
  </label>
</template>
