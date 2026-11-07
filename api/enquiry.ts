// POST /api/enquiry — "Check Price" on the home page.
// Saves the enquiry and sends the admin_enquiry WhatsApp.
import { waitUntil } from '@vercel/functions';
import { db, getSettings, must } from '../lib/db';
import { ipHash, route } from '../lib/http';
import { assertNotSpam } from '../lib/rate-limit';
import { enquiryInput } from '../lib/validate';
import { adminEnquiry, sendWhatsApp } from '../lib/whatsapp';

async function lowestFare(type: string, pickup: string, drop: string | null): Promise<number | null> {
  if (type === 'local-rental' || !drop) return null;
  const { data } = await db().from('route_fares').select('hatchback_price, sedan_price, suv_price')
    .eq('pickup', pickup).eq('drop', drop).maybeSingle();
  return data ? Math.min(data.hatchback_price, data.sedan_price, data.suv_price) : null;
}

export default route({ methods: ['POST'], cors: true }, async (req, res) => {
  const input = enquiryInput.parse(req.body);
  const ip = ipHash(req);

  await assertNotSpam('enquiries', { ipHash: ip, mobile: input.mobile, perIp: 20, perMobile: 10, minutes: 10 });

  // Lowest fare we showed them, so the office can quote it on the follow-up call.
  const quoted = await lowestFare(input.serviceType, input.pickup, input.dropOrPackage);

  const [settings, saved] = await Promise.all([
    getSettings(),
    db().from('enquiries').insert({
      quoted_fare: quoted,
      service_type: input.serviceType,
      pickup: input.pickup,
      drop_or_package: input.dropOrPackage,
      mobile: input.mobile,
      ip_hash: ip,
    }).select('id, created_at').single(),
  ]);
  const enquiry = must(saved, 'save enquiry');

  waitUntil(sendWhatsApp(settings, adminEnquiry(settings, {
    serviceType: input.serviceType,
    pickup: input.pickup,
    dropOrPackage: input.dropOrPackage,
    mobile: input.mobile,
    at: new Date(enquiry.created_at),
  })));

  res.status(201).json({ ok: true, enquiryId: enquiry.id });
});
