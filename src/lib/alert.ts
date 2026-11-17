import { ref } from 'vue';

/** Bunyi peringatan pesanan online yang menunggu konfirmasi. Preferensi per perangkat. Browser baru mengizinkan suara setelah pengguna menyentuh halaman sekali. */
const KEY = 'admin_alert_sound';
export const soundOn = ref((() => { try { return localStorage.getItem(KEY) !== '0'; } catch { return true; } })());   // bawaan: hidup
export function setSound(on: boolean) { soundOn.value = on; try { localStorage.setItem(KEY, on ? '1' : '0'); } catch { /* abaikan */ } if (on) { unlockAudio(); beep(); } }

let ctx: AudioContext | null = null;
export const audioReady = ref(false);
export function unlockAudio() {
  try {
    const AC = window.AudioContext || (window as any).webkitAudioContext; if (!AC) return;
    ctx ??= new AC(); if (ctx.state === 'suspended') ctx.resume().then(() => (audioReady.value = ctx!.state === 'running')).catch(() => {}); else audioReady.value = ctx.state === 'running';
  } catch { /* abaikan */ }
}
/** Dua nada pendek naik. */
export function beep() {
  if (!ctx || ctx.state !== 'running') return;
  const now = ctx.currentTime;
  [[880, 0], [1175, 0.22]].forEach(([f, d]) => {
    const o = ctx!.createOscillator(), g = ctx!.createGain();
    o.type = 'sine'; o.frequency.value = f; o.connect(g); g.connect(ctx!.destination);
    g.gain.setValueAtTime(0.0001, now + d); g.gain.exponentialRampToValueAtTime(0.35, now + d + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, now + d + 0.2);
    o.start(now + d); o.stop(now + d + 0.22);
  });
}
let started = false;
export function initAlert() {
  if (started) return; started = true;
  for (const ev of ['pointerdown', 'keydown', 'touchstart']) addEventListener(ev, unlockAudio, { passive: true });
}
