// MSG91 WhatsApp templates. Names, namespace and body_N order must match the
// approved templates in MSG91 exactly — change values here, never the shape.
import { env } from './env';
import type { Settings } from './db';
import { displayDate, istDate, istTime } from './format';

type Components = Record<string, { type: 'text'; value: string; subtype?: 'url' }>;

export interface TemplateMessage {
  template: string;
  to: string[];
  components: Components;
}

const text = (value: unknown) => ({ type: 'text' as const, value: String(value ?? '-').trim() || '-' });
const body = (values: unknown[]): Components =>
  Object.fromEntries(values.map((v, i) => [`body_${i + 1}`, text(v)]));

/** 10-digit Indian mobile -> '91XXXXXXXXXX'. */
export const toWhatsApp = (mobile: string) => (mobile.length === 10 ? `91${mobile}` : mobile);

/** 'https://rzp.io/rzp/AbC12' -> 'rzp/AbC12' (template URL is 'https://rzp.io/{{1}}'). */
export const payButtonValue = (paymentLink: string) => paymentLink.replace('https://rzp.io/', '');

export interface BookingForMessage {
  id: number;
  booking_type: string;
  car_type: string;
  pickup_location: string;
  drop_location: string | null;
  rental_package: string | null;
  pickup_address: string;
  pickup_date: string;      // YYYY-MM-DD
  pickup_time: string;
  customer_name: string;
  mobile: string;
  email: string | null;
  passengers: number;
  fare: number;
}

// ---------- the 6 approved templates ----------------------------------

export function adminEnquiry(
  settings: Settings,
  e: { pickup: string; dropOrPackage: string | null; mobile: string; at?: Date },
): TemplateMessage {
  return {
    template: 'admin_enquiry',
    to: settings.admin_whatsapp_numbers,
    components: body([e.pickup, e.dropOrPackage, e.mobile, istDate(e.at), istTime(e.at)]),
  };
}

export function adminBooking(settings: Settings, b: BookingForMessage): TemplateMessage {
  return {
    template: 'admin_booking_enquiry',
    to: settings.admin_whatsapp_numbers,
    components: body([
      b.id, b.customer_name, b.booking_type, b.car_type, b.pickup_location,
      b.drop_location ?? b.rental_package, b.pickup_address, displayDate(b.pickup_date, true),
      b.pickup_time, b.mobile, b.email, b.passengers, b.fare,
    ]),
  };
}

export function customerBooking(b: BookingForMessage, paymentLink: string): TemplateMessage {
  return {
    template: b.booking_type === 'local-rental' ? 'customer_local_rental_enquiry' : 'customer_booking_enquiry',
    to: [toWhatsApp(b.mobile)],
    components: {
      ...body([
        b.customer_name, b.id, b.booking_type, b.car_type, b.pickup_location,
        b.drop_location ?? b.rental_package, b.pickup_address, displayDate(b.pickup_date, false),
        b.pickup_time, b.fare,
      ]),
      button_1: { subtype: 'url', type: 'text', value: payButtonValue(paymentLink) },
    },
  };
}

export function customerAdvancePaid(p: { customer_name: string; advance_amount: number; booking_id: number; mobile: string }): TemplateMessage {
  return {
    template: 'customer_advance_payment_enquiry',
    to: [toWhatsApp(p.mobile)],
    components: body([p.customer_name, p.advance_amount, p.booking_id]),
  };
}

export function adminAdvancePaid(
  settings: Settings,
  p: { customer_name: string; advance_amount: number; booking_id: number; mobile: string },
): TemplateMessage {
  return {
    template: 'admin_advance_payment_enquiry',
    to: settings.admin_whatsapp_numbers,
    components: body([p.booking_id, p.customer_name, p.mobile, p.advance_amount]),
  };
}

// ---------- sending ----------------------------------------------------

/** Exact MSG91 bulk payload (same structure the live site sends today). */
export function msg91Payload(settings: Settings, msg: TemplateMessage) {
  return {
    integrated_number: settings.whatsapp_sender,
    content_type: 'template',
    payload: {
      messaging_product: 'whatsapp',
      type: 'template',
      template: {
        name: msg.template,
        language: { code: 'en', policy: 'deterministic' },
        namespace: settings.whatsapp_namespace,
        to_and_components: [{ to: msg.to, components: msg.components }],
      },
    },
  };
}

/** Sends one template. Never throws — a failed WhatsApp must not fail a booking. */
export async function sendWhatsApp(settings: Settings, msg: TemplateMessage): Promise<boolean> {
  try {
    const res = await fetch('https://api.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', authkey: env.msg91AuthKey },
      body: JSON.stringify(msg91Payload(settings, msg)),
      signal: AbortSignal.timeout(8000),
    });
    const result = await res.text();
    if (!res.ok) console.error(`WhatsApp ${msg.template} failed`, res.status, result);
    return res.ok;
  } catch (err) {
    console.error(`WhatsApp ${msg.template} error`, err);
    return false;
  }
}
