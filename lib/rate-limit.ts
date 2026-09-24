import { db } from './db';
import { HttpError } from './http';

/**
 * Simple spam guard using rows we already store (no Redis needed).
 * Counts recent rows in `table` with the same ip_hash or mobile.
 */
export async function assertNotSpam(
  table: 'enquiries' | 'bookings',
  p: { ipHash: string; mobile: string; perIp: number; perMobile: number; minutes: number },
): Promise<void> {
  const since = new Date(Date.now() - p.minutes * 60_000).toISOString();
  const [byIp, byMobile] = await Promise.all([
    db().from(table).select('id', { count: 'exact', head: true }).eq('ip_hash', p.ipHash).gte('created_at', since),
    db().from(table).select('id', { count: 'exact', head: true }).eq('mobile', p.mobile).gte('created_at', since),
  ]);
  if ((byIp.count ?? 0) >= p.perIp || (byMobile.count ?? 0) >= p.perMobile) {
    throw new HttpError(429, 'Too many requests. Please wait a few minutes or call us.');
  }
}
