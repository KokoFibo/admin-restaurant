/** Skema warna website. id HARUS sama dengan daftar di database (set_tenant_theme) dan template frontend. */
export type Preset = { id: string; name: string; primary: string; secondary: string; accent: string; bg: string; bg2: string };
export const PRESETS: Preset[] = [
  { id: 'giok', name: 'Giok klasik', primary: '#2B5B47', secondary: '#3D735B', accent: '#C35B3B', bg: '#FBF8F2', bg2: '#F4EEE2' },
  { id: 'teh', name: 'Teh hangat', primary: '#7A4A21', secondary: '#96623A', accent: '#A8402A', bg: '#FBF7F0', bg2: '#F3EADB' },
  { id: 'samudra', name: 'Biru samudra', primary: '#1F4E6B', secondary: '#2F6F94', accent: '#B45F14', bg: '#F6F9FB', bg2: '#E8EFF4' },
  { id: 'bata', name: 'Merah bata', primary: '#8E2A2A', secondary: '#A84545', accent: '#8A6414', bg: '#FCF8F4', bg2: '#F5EBE1' },
  { id: 'anggur', name: 'Ungu anggur', primary: '#5B3A66', secondary: '#75507F', accent: '#A5561B', bg: '#FAF7FA', bg2: '#EFE8F1' },
  { id: 'zaitun', name: 'Zaitun', primary: '#4F5D2F', secondary: '#6B7B45', accent: '#B0532E', bg: '#FAF9F3', bg2: '#EFEDDC' },
  { id: 'arang', name: 'Arang', primary: '#2E3A3F', secondary: '#46565C', accent: '#C4481F', bg: '#F8F8F6', bg2: '#ECECE8' },
];
/** Warna dasar yang boleh dipilih Owner (harus sama dengan v_bgs di set_tenant_theme). Super Admin bebas. */
export const OWNER_BGS: [string, string][] = [['Putih', '#FFFFFF'], ['Putih hangat', '#FBF8F2'], ['Krem', '#FAF5EA'], ['Abu muda', '#F5F5F3'], ['Hijau pucat', '#F3F8F4'], ['Biru pucat', '#F2F7FA']];

const rgb = (h: string) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const hex = (c: number[]) => '#' + c.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('').toUpperCase();
export const mix = (a: string, b: string, t: number) => { const x = rgb(a), y = rgb(b); return hex(x.map((v, i) => v * (1 - t) + y[i] * t)); };
const lum = (h: string) => { const [r, g, b] = rgb(h).map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
export const contrast = (a: string, b: string) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
export const isHex = (h: string) => /^#[0-9a-fA-F]{6}$/.test(h);
/** Warna turunan (rumus yang sama dipakai template): secondary = primary+15% putih, bg2 = dasar+6% primary, teks gelap/terang menurut mode. */
export const derive = (primary: string, accent: string, bg: string, dark = false) =>
  ({ primary, accent, bg, secondary: mix(primary, '#FFFFFF', 0.15), bg2: mix(bg, primary, 0.06), ink: dark ? '#F2EFE9' : '#1E2621' });
