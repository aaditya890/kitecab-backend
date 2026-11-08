// GET /api/pay-link?id=<bookingId>&t=<payToken>
// The website asks this right after booking until the advance link is ready (usually 1-2 s).
import { db } from '../lib/db';
import { HttpError, route } from '../lib/http';
import { validPayToken } from '../lib/pay-token';

export default route({ methods: ['GET'], cors: true }, async (req, res) => {
  const id = Number(req.query.id);
  const token = String(req.query.t ?? '');
  if (!Number.isInteger(id) || id <= 0 || !validPayToken(id, token)) throw new HttpError(404, 'Not found');

  const { data, error } = await db()
    .from('booking_payments')
    .select('status, payment_link')
    .eq('booking_id', id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(`pay link: ${error.message}`);

  res.setHeader('Cache-Control', 'no-store');
  if (!data) return res.json({ ok: true, status: 'preparing' });
  res.json({ ok: true, status: data.status === 'PAID' ? 'paid' : 'ready', paymentLink: data.status === 'PENDING' ? data.payment_link : null });
});
