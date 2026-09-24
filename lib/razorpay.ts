import { createHmac, timingSafeEqual } from 'node:crypto';
import { env } from './env';

export interface PaymentLink {
  id: string;         // plink_...
  short_url: string;  // https://rzp.io/rzp/...
}

/** Creates a Razorpay payment link (REST API — no SDK needed). */
export async function createPaymentLink(p: {
  bookingId: number;
  amount: number;        // rupees
  customerName: string;
  mobile: string;
  email?: string | null;
  attempt?: number;      // >1 when admin re-issues a link (reference_id must be unique)
}): Promise<PaymentLink> {
  const auth = Buffer.from(`${env.razorpayKeyId}:${env.razorpayKeySecret}`).toString('base64');
  const referenceId = p.attempt && p.attempt > 1 ? `BOOKING_${p.bookingId}_${p.attempt}` : `BOOKING_${p.bookingId}`;
  const res = await fetch('https://api.razorpay.com/v1/payment_links', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Basic ${auth}` },
    body: JSON.stringify({
      amount: p.amount * 100, // paise
      currency: 'INR',
      description: `Advance Payment - Booking #${p.bookingId}`,
      reference_id: referenceId,
      customer: { name: p.customerName, contact: `+91${p.mobile}`, ...(p.email ? { email: p.email } : {}) },
      notify: { sms: false, email: false },   // we notify on WhatsApp ourselves
      reminder_enable: true,
      notes: { booking_id: String(p.bookingId) },
    }),
    signal: AbortSignal.timeout(10000),
  });
  const data = await res.json() as PaymentLink & { error?: { description?: string } };
  if (!res.ok) throw new Error(`Razorpay payment link failed: ${data.error?.description ?? res.status}`);
  return { id: data.id, short_url: data.short_url };
}

/** Cancels an unpaid link so an old link can't be paid after a new one is issued. */
export async function cancelPaymentLink(linkId: string): Promise<void> {
  const auth = Buffer.from(`${env.razorpayKeyId}:${env.razorpayKeySecret}`).toString('base64');
  const res = await fetch(`https://api.razorpay.com/v1/payment_links/${encodeURIComponent(linkId)}/cancel`, {
    method: 'POST',
    headers: { Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) console.error('Razorpay cancel failed', linkId, res.status, await res.text());
}

/** Verifies the X-Razorpay-Signature header against the raw request body. */
export function verifyWebhookSignature(rawBody: string, signature: string | undefined, secret = env.razorpayWebhookSecret): boolean {
  if (!signature) return false;
  const expected = createHmac('sha256', secret).update(rawBody).digest('hex');
  const a = Buffer.from(expected);
  const b = Buffer.from(signature);
  return a.length === b.length && timingSafeEqual(a, b);
}
