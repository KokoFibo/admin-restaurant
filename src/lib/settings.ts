/** Sub-tab halaman Pengaturan, berurutan, dan siapa yang boleh melihatnya (sama dengan hak di store.can). */
export const SETTINGS_ORDER = ['profil', 'situs', 'menu', 'istilah', 'pajak', 'online', 'konfig', 'perangkat', 'banner', 'hapus'] as const;
export type SettingsSection = (typeof SETTINGS_ORDER)[number];
const OWNER = ['super_admin', 'owner'];
export function settingsFor(role: string, isMaster: boolean): SettingsSection[] {
  const ok = (s: SettingsSection) =>
    s === 'perangkat' ? true
    : s === 'banner' ? [...OWNER, 'manager'].includes(role)
    : s === 'hapus' ? isMaster
    : OWNER.includes(role);                // profil, situs, menu, istilah, pajak, online, konfig
  return SETTINGS_ORDER.filter(ok);
}
