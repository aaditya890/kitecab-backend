import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { test } from 'node:test';
import resend from '../api/admin/resend';
import booking from '../api/booking';
import enquiry from '../api/enquiry';
import webhook from '../api/razorpay-webhook';

process.env.RAZORPAY_WEBHOOK_SECRET = 'whsec_test';
process.env.ALLOWED_ORIGINS = 'https://kitecab.com';

function call(handler: any, opts: { method: string; headers?: Record<string, string>; body?: unknown; raw?: string }) {
  const req: any = Readable.from([Buffer.from(opts.raw ?? '')]);
  Object.assign(req, { method: opts.method, headers: opts.headers ?? {}, body: opts.body, socket: {} });
  return new Promise<{ status: number; headers: Record<string, string>; json: any }>((resolve) => {
    const out = { status: 200, headers: {} as Record<string, string>, json: undefined as any };
    const res: any = {
      setHeader: (k: string, v: string) => { out.headers[k.toLowerCase()] = v; },
      status: (s: number) => { out.status = s; return res; },
      json: (j: unknown) => { out.json = j; resolve(out); return res; },
      end: () => { resolve(out); return res; },
    };
    handler(req, res);
  });
}

test('CORS preflight only for kitecab.com', async () => {
  const ok = await call(enquiry, { method: 'OPTIONS', headers: { origin: 'https://kitecab.com' } });
  assert.equal(ok.status, 204);
  assert.equal(ok.headers['access-control-allow-origin'], 'https://kitecab.com');
  const evil = await call(enquiry, { method: 'OPTIONS', headers: { origin: 'https://evil.example' } });
  assert.equal(evil.headers['access-control-allow-origin'], undefined);
});

test('enquiry rejects fake mobile before touching the database', async () => {
  const r = await call(enquiry, { method: 'POST', body: { serviceType: 'oneway', pickup: 'Raipur', dropOrPackage: 'Durg', mobile: '0000000000' } });
  assert.equal(r.status, 400);
  assert.match(r.json.message, /mobile/);
});

test('booking rejects GET', async () => {
  assert.equal((await call(booking, { method: 'GET' })).status, 405);
});

test('webhook rejects forged payment', async () => {
  const raw = JSON.stringify({ event: 'payment_link.paid', payload: { payment_link: { entity: { id: 'plink_x' } } } });
  const r = await call(webhook, { method: 'POST', raw, headers: { 'x-razorpay-signature': 'deadbeef' } });
  assert.equal(r.status, 401);
});

test('admin endpoint needs login', async () => {
  const r = await call(resend, { method: 'POST', body: { bookingId: 1, action: 'admin-whatsapp' } });
  assert.equal(r.status, 401);
});
