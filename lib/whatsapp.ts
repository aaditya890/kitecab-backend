// MSG91 WhatsApp templates (kc_* set, see docs/whatsapp-templates-v2.md).
// Names, namespace and body_N order must match the templates in MSG91 exactly.
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
  pickup_date: string;
  pickup_time: string;
  customer_name: string;
  mobile: string;
  email: string | null;
  passengers: number;
  fare: number;
  advance_amount?: number | null;
}

const TYPE_LABEL: Record<string, string> = { oneway: 'One way', 'round-trip': 'Round trip', 'local-rental': 'Local rental' };
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** 'One way, Sedan' */
export const tripAndCar = (b: BookingForMessage) => `${TYPE_LABEL[b.booking_type] ?? b.booking_type}, ${b.car_type}`;

/** 'Raipur to Bilaspur', or for a rental 'Raipur · 8hour 80km'. */
export const routeText = (b: BookingForMessage) =>
  b.booking_type === 'local-rental' || !b.drop_location
    ? `${b.pickup_location} · ${b.rental_package ?? 'local rental'}`
    : `${b.pickup_location} to ${b.drop_location}`;

/** '25 Oct 2026, 6:30 PM' */
export const pickupText = (b: { pickup_date: string; pickup_time: string }) => `${displayDate(b.pickup_date, true)}, ${b.pickup_time}`;

/** '24 Oct, 4:51 PM' in India time. */
export function enquiryTime(at = new Date()): string {
  const d = new Date(at.getTime() + 330 * 60_000);
  const h = d.getUTCHours() % 12 || 12;
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}, ${h}:${String(d.getUTCMinutes()).padStart(2, '0')} ${d.getUTCHours() < 12 ? 'AM' : 'PM'}`;
}

const money = (n: number | null | undefined) => Number(n ?? 0).toLocaleString('en-IN');

// ---------- the 6 kc_* templates ----------------------------------------

/** kc_enquiry_admin: service, pickup, drop/package, mobile, time */
export function adminEnquiry(
  settings: Settings,
  e: { serviceType?: string | null; pickup: string; dropOrPackage: string | null; mobile: string; at?: Date },
): TemplateMessage {
  return {
    template: 'kc_enquiry_admin',
    to: settings.admin_whatsapp_numbers,
    components: body([TYPE_LABEL[e.serviceType ?? ''] ?? 'Cab', e.pickup, e.dropOrPackage, e.mobile, enquiryTime(e.at)]),
  };
}

/** kc_booking_admin: id, name, mobile, trip+car, route, address, pickup, passengers, fare, advance */
export function adminBooking(settings: Settings, b: BookingForMessage): TemplateMessage {
  return {
    template: 'kc_booking_admin',
    to: settings.admin_whatsapp_numbers,
    components: body([
      b.id, b.customer_name, b.mobile, tripAndCar(b), routeText(b), b.pickup_address,
      pickupText(b), b.passengers, money(b.fare), money(b.advance_amount),
    ]),
  };
}

/** kc_booking_customer: name, id, trip+car, route, address, pickup, fare, advance + Pay button */
export function customerBooking(b: BookingForMessage, paymentLink: string): TemplateMessage {
  return {
    template: 'kc_booking_customer',
    to: [toWhatsApp(b.mobile)],
    components: {
      ...body([
        b.customer_name, b.id, tripAndCar(b), routeText(b), b.pickup_address,
        pickupText(b), money(b.fare), money(b.advance_amount),
      ]),
      button_1: { subtype: 'url', type: 'text', value: payButtonValue(paymentLink) },
    },
  };
}

interface PaidDetails {
  customer_name: string;
  advance_amount: number;
  booking_id: number;
  mobile: string;
  razorpay_payment_id?: string | null;
}

/** kc_payment_customer: name, advance, booking id */
export function customerAdvancePaid(p: PaidDetails): TemplateMessage {
  return {
    template: 'kc_payment_customer',
    to: [toWhatsApp(p.mobile)],
    components: body([p.customer_name, money(p.advance_amount), p.booking_id]),
  };
}

/** kc_payment_admin: id, name, mobile, advance, Razorpay payment id */
export function adminAdvancePaid(settings: Settings, p: PaidDetails): TemplateMessage {
  return {
    template: 'kc_payment_admin',
    to: settings.admin_whatsapp_numbers,
    components: body([p.booking_id, p.customer_name, p.mobile, money(p.advance_amount), p.razorpay_payment_id]),
  };
}

/** kc_driver_assigned: name, id, driver name, driver mobile, car model, car number, pickup */
export function driverAssigned(
  b: BookingForMessage,
  d: { driverName: string; driverMobile: string; carModel: string | null; carNumber: string | null },
): TemplateMessage {
  return {
    template: 'kc_driver_assigned',
    to: [toWhatsApp(b.mobile)],
    components: body([b.customer_name, b.id, d.driverName, d.driverMobile, d.carModel, d.carNumber, pickupText(b)]),
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

/** Test mode: send every message to one number (see WHATSAPP_TEST_NUMBER). */
export function redirectForTesting(msg: TemplateMessage, testNumber: string | undefined): TemplateMessage {
  return testNumber ? { ...msg, to: [testNumber] } : msg;
}

/** Sends one template. Never throws — a failed WhatsApp must not fail a booking. */
export async function sendWhatsApp(settings: Settings, original: TemplateMessage): Promise<boolean> {
  const msg = redirectForTesting(original, env.whatsappTestNumber);
  if (msg !== original) console.info(`WhatsApp test mode: ${msg.template} -> ${msg.to[0]} (was ${original.to.join(', ')})`);
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
