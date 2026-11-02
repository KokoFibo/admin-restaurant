/** Hostname permintaan → bentuk baku untuk mencari tenant_domains (huruf kecil, tanpa port, tanpa titik akhir). */
const RESERVED_LABELS = new Set(['admin', 'api', 'www']);   // dilayani proyek lain (admin/API) atau halaman pemasaran

export function requestHost(request: Request): string | null {
  const raw = (request.headers.get('host') || new URL(request.url).host).split(':')[0].trim().toLowerCase().replace(/\.$/, '');
  return /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(raw) && raw.length <= 253 ? raw : null;
}

/** true bila host adalah subdomain platform yang dicadangkan (jangan dicari sebagai restoran). */
export function isReservedPlatformHost(host: string, baseDomain?: string): boolean {
  if (!baseDomain || !host.endsWith('.' + baseDomain)) return false;
  return RESERVED_LABELS.has(host.slice(0, -(baseDomain.length + 1)));
}
