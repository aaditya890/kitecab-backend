// POST /api/razorpay-webhook — called by Razorpay (not the browser).
// Verifies the signature, marks the payment PAID exactly once, confirms the
// booking and sends the payment WhatsApps.
import { waitUntil } from '@vercel/functions';
import { db, getSettings } from '../lib/db';
import { readRawBody, route } from '../lib/http';
import { verifyWebhookSignature } from '../lib/razorpay';
import { adminAdvancePaid, customerAdvancePaid, sendWhatsApp } from '../lib/whatsapp';

interface RazorpayEvent {
  event: string;
  payload: {
    payment_link?: { entity: { id: string; status: string } };
    payment?: { entity: { id: string; amount: number } };
  };
}

async function handlePaid(body: RazorpayEvent, raw: unknown) {
  const link = body.payload.payment_link?.entity;
  const payment = body.payload.payment?.entity;
  if (!link) return;

  // `status <> 'PAID'` makes this idempotent: Razorpay retries only update once.
  const { data: updated, error } = await db().from('payments')
    .update({
      status: 'PAID',
      paid_at: new Date().toISOString(),
      razorpay_payment_id: payment?.id ?? null,
      amount_paid: payment ? Math.round(payment.amount / 100) : null,
      webhook_response: raw,
    })
    .eq('razorpay_payment_link_id', link.id)
    .neq('status', 'PAID')
    .select('booking_id, customer_name, mobile, advance_amount');
  if (error) throw new Error(`update payment: ${error.message}`);
  const paid = updated?.[0];
  if (!paid) return; // unknown link or already processed

  // Bookings made on the legacy site may not exist in `bookings` yet — that's fine.
  await db().from('bookings').update({ status: 'confirmed' })
    .eq('id', paid.booking_id).eq('status', 'new');

  const settings = await getSettings();
  const details = {
    booking_id: Number(paid.booking_id),
    customer_name: paid.customer_name,
    mobile: String(paid.mobile),
    advance_amount: Number(paid.advance_amount),
  };
  waitUntil(Promise.allSettled([
    sendWhatsApp(settings, customerAdvancePaid(details)),
    sendWhatsApp(settings, adminAdvancePaid(settings, details)),
  ]));
}

async function handleClosed(body: RazorpayEvent, status: 'EXPIRED' | 'CANCELLED') {
  const link = body.payload.payment_link?.entity;
  if (!link) return;
  await db().from('payments').update({ status }).eq('razorpay_payment_link_id', link.id).eq('status', 'PENDING');
}

const handler = route({ methods: ['POST'] }, async (req, res) => {
  const raw = await readRawBody(req);
  if (!verifyWebhookSignature(raw, req.headers['x-razorpay-signature'] as string | undefined)) {
    return res.status(401).json({ ok: false, message: 'Invalid signature' });
  }

  const body = JSON.parse(raw) as RazorpayEvent;
  if (body.event === 'payment_link.paid') await handlePaid(body, body);
  else if (body.event === 'payment_link.expired') await handleClosed(body, 'EXPIRED');
  else if (body.event === 'payment_link.cancelled') await handleClosed(body, 'CANCELLED');

  res.status(200).json({ ok: true });
});

export default handler;

// Raw body is required for signature verification.
export const config = { api: { bodyParser: false } };
