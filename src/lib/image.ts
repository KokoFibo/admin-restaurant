/** Foto: potong sesuai rasio, kecilkan, simpan WebP ringan. Menu 4:3 (800 px, ≈60 KB); hero 4:5 (900 px, ≤140 KB). */
export const PHOTO_W = 800, PHOTO_MAX_BYTES = 60 * 1024;
export function cropRect(img: HTMLImageElement, px: number, py: number, ratio = 4 / 3) {
  const W = img.naturalWidth, H = img.naturalHeight;
  const sw = W / H > ratio ? H * ratio : W, sh = W / H > ratio ? H : W / ratio;
  return { sx: ((W - sw) * px) / 100, sy: ((H - sh) * py) / 100, sw, sh };
}
export function drawPreview(img: HTMLImageElement, c: HTMLCanvasElement, px: number, py: number, ratio = 4 / 3) {
  const r = cropRect(img, px, py, ratio); c.getContext('2d')!.drawImage(img, r.sx, r.sy, r.sw, r.sh, 0, 0, c.width, c.height);
}
export async function toWebp(img: HTMLImageElement, px: number, py: number, o: { ratio?: number; width?: number; maxBytes?: number } = {}): Promise<Blob> {
  const ratio = o.ratio ?? 4 / 3, maxBytes = o.maxBytes ?? PHOTO_MAX_BYTES;
  const r = cropRect(img, px, py, ratio), ow = Math.min(o.width ?? PHOTO_W, Math.round(r.sw)), oh = Math.round(ow / ratio);
  const c = document.createElement('canvas'); c.width = ow; c.height = oh;
  const ctx = c.getContext('2d')!; ctx.imageSmoothingQuality = 'high'; ctx.drawImage(img, r.sx, r.sy, r.sw, r.sh, 0, 0, ow, oh);
  let q = 0.8, blob: Blob;
  do { blob = await new Promise<Blob>(res => c.toBlob(b => res(b!), 'image/webp', q)); q -= 0.07; } while (blob.size > maxBytes && q > 0.3);
  if (blob.size > 150 * 1024) throw new Error('Foto terlalu besar setelah dikompres; pakai foto lain atau lebih sederhana.');
  return blob;
}
export const slug = (s: string) => s.normalize('NFKD').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
