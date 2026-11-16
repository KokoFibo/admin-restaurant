import { ref } from 'vue';

/** "Jaga layar tetap menyala" untuk tablet dapur/kasir. Preferensi disimpan per perangkat; dipasang ulang saat halaman kembali terlihat (browser melepasnya saat tab disembunyikan). */
const KEY = 'admin_wakelock';
export const wakeSupported = typeof navigator !== 'undefined' && 'wakeLock' in navigator;
export const wakeOn = ref((() => { try { return localStorage.getItem(KEY) === '1'; } catch { return false; } })());
export const wakeActive = ref(false); let lock: any = null;
async function acquire() {
  if (!wakeSupported || !wakeOn.value || document.visibilityState !== 'visible' || lock) return;
  try { lock = await (navigator as any).wakeLock.request('screen'); wakeActive.value = true; lock.addEventListener('release', () => { lock = null; wakeActive.value = false; }); } catch { lock = null; wakeActive.value = false; }
}
export async function setWake(on: boolean) {
  wakeOn.value = on; try { localStorage.setItem(KEY, on ? '1' : '0'); } catch { /* abaikan */ }
  if (on) await acquire(); else { try { await lock?.release(); } catch { /* abaikan */ } lock = null; wakeActive.value = false; }
}
let started = false;
export function initWake() { if (started) return; started = true; document.addEventListener('visibilitychange', acquire); acquire(); }
