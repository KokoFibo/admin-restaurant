/** Variabel lingkungan Cloudflare Pages Functions (Settings → Variables and Secrets). */
export const env = (e: any, k: string): string | undefined => e?.[k];
