import { ref } from 'vue';

/** Tema panel: 'system' (ikuti perangkat, bawaan) | 'light' | 'dark'. Disimpan per perangkat. Diterapkan ke <html data-theme>. */
export type ThemePref = 'system' | 'light' | 'dark';
const KEY = 'admin_theme', BG = { light: '#FBF8F2', dark: '#171F1B' };
const read = (): ThemePref => { try { const v = localStorage.getItem(KEY); return v === 'light' || v === 'dark' ? v : 'system'; } catch { return 'system'; } };
export const themePref = ref<ThemePref>(read());
const mq = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
export const resolvedTheme = (): 'light' | 'dark' => (themePref.value === 'system' ? (mq?.matches ? 'dark' : 'light') : themePref.value);
export function applyTheme() {
  const r = resolvedTheme(); document.documentElement.dataset.theme = r;
  document.querySelector('meta[name=theme-color]')?.setAttribute('content', BG[r]);
}
export function setTheme(p: ThemePref) { themePref.value = p; try { p === 'system' ? localStorage.removeItem(KEY) : localStorage.setItem(KEY, p); } catch { /* penyimpanan dinonaktifkan */ } applyTheme(); }
export function initTheme() { applyTheme(); mq?.addEventListener('change', () => themePref.value === 'system' && applyTheme()); }
