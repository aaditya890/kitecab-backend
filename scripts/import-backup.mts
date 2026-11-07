/**
 * DEV PROJECT ONLY — loads the backup CSVs into the empty `kitecab` / `payments`
 * tables made by supabase/dev/000_legacy_tables.sql.
 *
 *   npx tsx scripts/import-backup.mts ../_backup/2026-09-24
 *
 * Reads SUPABASE_URL + SUPABASE_SECRET_KEY from .env. Refuses to run on the live project.
 * Safe to run twice (upsert by id).
 */
import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs';
import path from 'node:path';

const DEV_REF = 'bnpxmvbylebxjgbuxihe';
const LIVE_REF = 'zakyzpxuqdkhrrhgwccn';

process.loadEnvFile?.('.env');
const url = process.env.SUPABASE_URL ?? '';
const key = process.env.SUPABASE_SECRET_KEY ?? '';
if (!url.includes(DEV_REF) || url.includes(LIVE_REF)) throw new Error(`Refusing: SUPABASE_URL is not the dev project (${DEV_REF}).`);
if (!key) throw new Error('SUPABASE_SECRET_KEY is empty in .env');

const dir = process.argv[2] ?? '../_backup/2026-09-24';
const db = createClient(url, key, { auth: { persistSession: false } });

/** RFC 4180 CSV parser (quoted fields, "" escapes, newlines inside quotes). */
function parseCsv(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let row: string[] = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') q = false;
      else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field); field = '';
      if (row.length > 1 || row[0] !== '') rows.push(row);
      row = [];
    } else field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  const [head, ...body] = rows;
  return body.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])));
}

const nil = (v: string) => (v === '' ? null : v);
const json = (v: string) => (v === '' ? null : JSON.parse(v));

async function load(table: string, rows: Record<string, unknown>[]) {
  for (let i = 0; i < rows.length; i += 200) {
    const { error } = await db.from(table).upsert(rows.slice(i, i + 200), { onConflict: 'id' });
    if (error) throw new Error(`${table} rows ${i}..: ${error.message}`);
  }
  const { count, error } = await db.from(table).select('id', { count: 'exact', head: true });
  if (error) throw error;
  console.log(`${table}: ${rows.length} in CSV, ${count} in table`);
}

const kitecab = parseCsv(fs.readFileSync(path.join(dir, 'kitecab_rows.csv'), 'utf8'))
  .map((r) => ({ id: Number(r.id), created_at: r.created_at, key: r.key, value: json(r.value) }));

const payments = parseCsv(fs.readFileSync(path.join(dir, 'payments_rows.csv'), 'utf8'))
  .map((r) => ({
    id: Number(r.id), created_at: nil(r.created_at), updated_at: nil(r.updated_at),
    booking_id: nil(r.booking_id), customer_name: nil(r.customer_name), mobile: nil(r.mobile),
    booking_amount: nil(r.booking_amount), advance_amount: nil(r.advance_amount),
    payment_type: nil(r.payment_type), status: nil(r.status), payment_link: nil(r.payment_link),
    razorpay_payment_link_id: nil(r.razorpay_payment_link_id), razorpay_payment_id: nil(r.razorpay_payment_id),
    reference_id: nil(r.reference_id), paid_at: nil(r.paid_at), webhook_response: json(r.webhook_response),
  }));

console.log(`parsed: kitecab ${kitecab.length}, payments ${payments.length}`);
await load("kitecab", kitecab);
await load('payments', payments);
