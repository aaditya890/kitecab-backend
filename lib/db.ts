import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { env } from './env';

let client: SupabaseClient | undefined;

/** Server-side Supabase client (secret key: bypasses RLS — never expose to the browser). */
export function db(): SupabaseClient {
  client ??= createClient(env.supabaseUrl, env.supabaseSecretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return client;
}

export interface Settings {
  advance_percent: number;
  whatsapp_sender: string;
  whatsapp_namespace: string;
  admin_whatsapp_numbers: string[];
  booking_open: boolean;
}

const DEFAULTS: Settings = {
  advance_percent: 20,
  whatsapp_sender: '919009611602',
  whatsapp_namespace: '5f6d7b38_402c_4432_b048_6a2ad7492956',
  admin_whatsapp_numbers: ['918187962796', '916263676216', '918963952633'],
  booking_open: true,
};

/** Business settings from the `settings` table (admin can change them without a deploy). */
export async function getSettings(): Promise<Settings> {
  const { data, error } = await db().from('settings').select('key, value').in('key', Object.keys(DEFAULTS));
  if (error) throw error;
  const fromDb = Object.fromEntries((data ?? []).map((row) => [row.key, row.value]));
  return { ...DEFAULTS, ...fromDb };
}

/** Throws a readable error when a Supabase call fails. */
export function must<T>(result: { data: T; error: { message: string } | null }, what: string): NonNullable<T> {
  if (result.error) throw new Error(`${what}: ${result.error.message}`);
  if (result.data === null) throw new Error(`${what}: no data`);
  return result.data as NonNullable<T>;
}
