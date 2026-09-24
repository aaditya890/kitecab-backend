// POST /api/enquiry — "Check Price" on the home page.
// Saves the enquiry and sends the admin_enquiry WhatsApp.
import { waitUntil } from '@vercel/functions';
import { db, getSettings, must } from '../lib/db';
import { ipHash, route } from '../lib/http';
import { assertNotSpam } from '../lib/rate-limit';
import { enquiryInput } from '../lib/validate';
import { adminEnquiry, sendWhatsApp } from '../lib/whatsapp';

export default route({ methods: ['POST'], cors: true }, async (req, res) => {
  const input = enquiryInput.parse(req.body);
  const ip = ipHash(req);

  await assertNotSpam('enquiries', { ipHash: ip, mobile: input.mobile, perIp: 20, perMobile: 10, minutes: 10 });

  const [settings, saved] = await Promise.all([
    getSettings(),
    db().from('enquiries').insert({
      service_type: input.serviceType,
      pickup: input.pickup,
      drop_or_package: input.dropOrPackage,
      mobile: input.mobile,
      ip_hash: ip,
    }).select('id, created_at').single(),
  ]);
  const enquiry = must(saved, 'save enquiry');

  waitUntil(sendWhatsApp(settings, adminEnquiry(settings, {
    pickup: input.pickup,
    dropOrPackage: input.dropOrPackage,
    mobile: input.mobile,
    at: new Date(enquiry.created_at),
  })));

  res.status(201).json({ ok: true, enquiryId: enquiry.id });
});
