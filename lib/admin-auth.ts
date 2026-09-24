import type { VercelRequest } from '@vercel/node';
import { db } from './db';
import { HttpError } from './http';

/** Checks the admin panel's Supabase login token and the `admin` role. */
export async function requireAdmin(req: VercelRequest): Promise<string> {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, '');
  if (!token) throw new HttpError(401, 'Please log in.');

  const { data, error } = await db().auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, 'Session expired. Please log in again.');

  const { data: profile } = await db().from('profiles').select('role').eq('id', data.user.id).maybeSingle();
  if (profile?.role !== 'admin') throw new HttpError(403, 'Admin access only.');
  return data.user.id;
}
