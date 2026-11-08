// POST /api/booking — customer confirms a cab.
// Replies as soon as the booking is saved (about one database round trip after the checks);
// the Razorpay advance link and the WhatsApps are prepared right after (GET /api/pay-link).
import { waitUntil } from '@vercel/functions';
import { createBooking, quote } from '../lib/booking';
import { getSettings } from '../lib/db';
import { ipHash, route } from '../lib/http';
import { payToken } from '../lib/pay-token';
import { assertNotSpam } from '../lib/rate-limit';
import { bookingInput } from '../lib/validate';

export default route({ methods: ['POST'], cors: true }, async (req, res) => {
  const input = bookingInput.parse(req.body);
  const ip = ipHash(req);

  // independent checks in parallel
  const [, settings, q] = await Promise.all([
    assertNotSpam('bookings', { ipHash: ip, mobile: input.customer.mobile, perIp: 6, perMobile: 4, minutes: 10 }),
    getSettings(),
    quote(input),
  ]);

  const result = await createBooking(input, settings, ip, q);
  waitUntil(result.afterReply);

  res.status(201).json({
    ok: true,
    bookingId: result.bookingId,
    fare: result.fare,
    advanceAmount: result.advanceAmount,
    paymentLink: null,
    payToken: result.advanceAmount > 0 ? payToken(result.bookingId) : null,
  });
});
