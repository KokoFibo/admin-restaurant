import { createApp } from 'vue';
import App from './App.vue';
import './styles.css';
import { initTheme } from './lib/theme';
import { initWake } from './lib/wakelock';
import { installEvt, online, checkVersion } from './store';

initTheme(); initWake();
createApp(App).mount('#app');

// PWA: tombol "Pasang aplikasi", status koneksi, dan pemberitahuan versi baru
addEventListener('beforeinstallprompt', (e: any) => { e.preventDefault(); installEvt.value = e; });
addEventListener('appinstalled', () => { installEvt.value = null; });
addEventListener('online', () => { online.value = true; checkVersion(); });
addEventListener('offline', () => { online.value = false; });
if (import.meta.env.PROD) {
  if ('serviceWorker' in navigator) addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(() => {}));
  setInterval(checkVersion, 5 * 60 * 1000);
  document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && checkVersion());
}
