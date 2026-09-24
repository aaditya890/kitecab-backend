// POST /api/admin/resend — admin panel actions that need server secrets.
//   { bookingId, action: 'customer-whatsapp' }  re-send booking message with the current pay link
//   { bookingId, action: 'admin-whatsapp' }     re-send the admin booking alert
//   { bookingId, action: 'new-payment-link' }   cancel old unpaid link, create a new one, WhatsApp it
import { z } from 'zod';
import { requireAdmin } from '../../lib/admin-auth';
import { db, getSettings, must } from '../../lib/db';
import { HttpError, route } from '../../lib/http';
import { advanceFor } from '../../lib/pricing';
import { cancelPaymentLink, createPaymentLink } from '../../lib/razorpay';
import { adminBooking, customerBooking, sendWhatsApp, type BookingForMessage } from '../../lib/whatsapp';

const input = z.object({
  bookingId: z.number().int().positive(),
  action: z.enum(['customer-whatsapp', 'admin-whatsapp', 'new-payment-link']),
});

export default route({ methods: ['POST'], cors: true }, async (req, res) => {
  await requireAdmin(req);
  const { bookingId, action } = input.parse(req.body);

  const settings = await getSettings();
  const booking = (await db().from('bookings').select('*').eq('id', bookingId).maybeSingle()).data as
    (BookingForMessage & { advance_amount: number | null }) | null;
  if (!booking) throw new HttpError(404, 'Booking not found.');

  const payments = must(
    await db().from('payments').select('*').eq('booking_id', bookingId).order('created_at', { ascending: false }),
    'load payments',
  );
  if (payments.some((p) => p.status === 'PAID') && action === 'new-payment-link') {
    throw new HttpError(409, 'Advance is already paid for this booking.');
  }

  if (action === 'admin-whatsapp') {
    const sent = await sendWhatsApp(settings, adminBooking(settings, booking));
    return res.json({ ok: sent });
  }

  if (action === 'customer-whatsapp') {
    const pending = payments.find((p) => p.status === 'PENDING');
    if (!pending) throw new HttpError(409, 'No unpaid payment link. Create a new link instead.');
    const sent = await sendWhatsApp(settings, customerBooking(booking, pending.payment_link));
    return res.json({ ok: sent, paymentLink: pending.payment_link });
  }

  // new-payment-link
  for (const p of payments.filter((p) => p.status === 'PENDING')) {
    await cancelPaymentLink(p.razorpay_payment_link_id);
    await db().from('payments').update({ status: 'CANCELLED' }).eq('id', p.id);
  }
  const amount = booking.advance_amount ?? advanceFor(booking.fare, settings.advance_percent);
  const attempt = Math.max(0, ...payments.map((p) => Number(p.attempt ?? 1))) + 1;
  const link = await createPaymentLink({
    bookingId, amount, customerName: booking.customer_name, mobile: booking.mobile, email: booking.email, attempt,
  });
  must(await db().from('payments').insert({
    booking_id: bookingId,
    customer_name: booking.customer_name,
    mobile: booking.mobile,
    booking_amount: booking.fare,
    advance_amount: amount,
    payment_type: 'ADVANCE',
    status: 'PENDING',
    payment_link: link.short_url,
    razorpay_payment_link_id: link.id,
    reference_id: attempt > 1 ? `BOOKING_${bookingId}_${attempt}` : `BOOKING_${bookingId}`,
    attempt,
  }).select('id'), 'save payment');

  const sent = await sendWhatsApp(settings, customerBooking(booking, link.short_url));
  res.json({ ok: true, whatsappSent: sent, paymentLink: link.short_url });
});
