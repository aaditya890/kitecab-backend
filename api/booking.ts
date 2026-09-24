// POST /api/booking — customer confirms a cab.
// Server calculates the fare, saves the booking, creates the advance payment link
// and sends the booking WhatsApps (admin + customer with "Pay Advance" button).
import { waitUntil } from '@vercel/functions';
import { createBooking } from '../lib/booking';
import { getSettings } from '../lib/db';
import { ipHash, route } from '../lib/http';
import { assertNotSpam } from '../lib/rate-limit';
import { bookingInput } from '../lib/validate';

export default route({ methods: ['POST'], cors: true }, async (req, res) => {
  const input = bookingInput.parse(req.body);
  const ip = ipHash(req);

  await assertNotSpam('bookings', { ipHash: ip, mobile: input.customer.mobile, perIp: 6, perMobile: 4, minutes: 10 });

  const settings = await getSettings();
  const result = await createBooking(input, settings, ip);
  waitUntil(result.notifications);

  res.status(201).json({
    ok: true,
    bookingId: result.bookingId,
    fare: result.fare,
    advanceAmount: result.advanceAmount,
    paymentLink: result.paymentLink,
  });
});
