import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import type { Settings } from '../lib/db';
import { displayDate, istDate, istTime, istToday } from '../lib/format';
import { advanceFor, priceFor, roundTripFare } from '../lib/pricing';
import { verifyWebhookSignature } from '../lib/razorpay';
import { bookingInput, enquiryInput, mobile } from '../lib/validate';
import {
  adminAdvancePaid, adminBooking, adminEnquiry, customerAdvancePaid, customerBooking, msg91Payload,
} from '../lib/whatsapp';

const settings: Settings = {
  advance_percent: 20,
  whatsapp_sender: '919009611602',
  whatsapp_namespace: '5f6d7b38_402c_4432_b048_6a2ad7492956',
  admin_whatsapp_numbers: ['918187962796', '916263676216', '918963952633'],
  booking_open: true,
};

const booking = {
  id: 999970, booking_type: 'oneway', car_type: 'Sedan', pickup_location: 'Raipur', drop_location: 'Bilaspur',
  rental_package: null, pickup_address: 'Telibandha', pickup_date: '2026-09-24', pickup_time: '6:30 PM',
  customer_name: 'Test User', mobile: '9876543210', email: 't@example.com', passengers: 2, fare: 2200,
};

// ---------- pricing (same numbers as the live site) ----------
test('route price per car type', () => {
  const r = { hatchback_price: 2100, sedan_price: 2200, suv_price: 2900 };
  assert.equal(priceFor(r, 'Hatchback'), 2100);
  assert.equal(priceFor(r, 'Sedan'), 2200);
  assert.equal(priceFor(r, 'SUV'), 2900);
});

test('round trip matches legacy formula (1-3 hours, 100 km)', () => {
  const rate = { waiting_slot: '1-3 hours', hatchback_per_km: 10, sedan_per_km: 11, suv_per_km: 16,
    hatchback_base: 1200, sedan_base: 1200, suv_base: 1400 };
  assert.equal(roundTripFare(rate, 'Hatchback', 100), 100 * 10 + 1200);
  assert.equal(roundTripFare(rate, 'Sedan', 100), 100 * 11 + 1200);
  assert.equal(roundTripFare(rate, 'SUV', 100), 100 * 16 + 1400);
});

test('advance = 20% rounded like the legacy API', () => {
  assert.equal(advanceFor(2100, 20), 420);
  assert.equal(advanceFor(2930, 20), 586);
  assert.equal(advanceFor(1150, 20), 230);
});

// ---------- WhatsApp payloads ----------
test('msg91 payload has the exact legacy shape', () => {
  const p = msg91Payload(settings, adminBooking(settings, booking));
  assert.deepEqual(Object.keys(p), ['integrated_number', 'content_type', 'payload']);
  assert.equal(p.integrated_number, '919009611602');
  assert.equal(p.payload.template.name, 'admin_booking_enquiry');
  assert.deepEqual(p.payload.template.language, { code: 'en', policy: 'deterministic' });
  assert.equal(p.payload.template.namespace, '5f6d7b38_402c_4432_b048_6a2ad7492956');
  assert.deepEqual(p.payload.template.to_and_components[0].to, settings.admin_whatsapp_numbers);
});

test('admin_booking_enquiry: 13 fields in template order', () => {
  const c = adminBooking(settings, booking).components;
  assert.deepEqual(Object.values(c).map((v) => v.value), [
    '999970', 'Test User', 'oneway', 'Sedan', 'Raipur', 'Bilaspur', 'Telibandha',
    '24 Sep 2026', '6:30 PM', '9876543210', 't@example.com', '2', '2200',
  ]);
});

test('customer_booking_enquiry: 10 fields + pay button', () => {
  const m = customerBooking(booking, 'https://rzp.io/rzp/AbC12');
  assert.equal(m.template, 'customer_booking_enquiry');
  assert.deepEqual(m.to, ['919876543210']);
  assert.deepEqual(Object.keys(m.components), [
    'body_1', 'body_2', 'body_3', 'body_4', 'body_5', 'body_6', 'body_7', 'body_8', 'body_9', 'body_10', 'button_1',
  ]);
  assert.equal(m.components.body_8.value, '24 Sep');
  assert.deepEqual(m.components.button_1, { subtype: 'url', type: 'text', value: 'rzp/AbC12' });
});

test('local rental uses rental template and package as drop', () => {
  const m = customerBooking({ ...booking, booking_type: 'local-rental', drop_location: null, rental_package: '8hour 80km' },
    'https://rzp.io/rzp/X');
  assert.equal(m.template, 'customer_local_rental_enquiry');
  assert.equal(m.components.body_6.value, '8hour 80km');
});

test('admin_enquiry: 5 fields, IST date/time', () => {
  const at = new Date('2026-09-24T11:21:00Z'); // 4:51 PM IST
  const c = adminEnquiry(settings, { pickup: 'Raipur', dropOrPackage: 'Durg', mobile: '9876543210', at }).components;
  assert.deepEqual(Object.values(c).map((v) => v.value), ['Raipur', 'Durg', '9876543210', '24/09/2026', '04:51 pm']);
});

test('payment templates: customer 3 fields, admin 4 fields', () => {
  const p = { customer_name: 'Test User', advance_amount: 420, booking_id: 999970, mobile: '9876543210' };
  assert.deepEqual(Object.values(customerAdvancePaid(p).components).map((v) => v.value), ['Test User', '420', '999970']);
  assert.deepEqual(Object.values(adminAdvancePaid(settings, p).components).map((v) => v.value),
    ['999970', 'Test User', '9876543210', '420']);
});

// ---------- security ----------
test('webhook signature: accepts valid, rejects forged', () => {
  const body = JSON.stringify({ event: 'payment_link.paid' });
  const sig = createHmac('sha256', 'whsec').update(body).digest('hex');
  assert.equal(verifyWebhookSignature(body, sig, 'whsec'), true);
  assert.equal(verifyWebhookSignature(body, sig, 'other-secret'), false);
  assert.equal(verifyWebhookSignature(body + ' ', sig, 'whsec'), false);
  assert.equal(verifyWebhookSignature(body, undefined, 'whsec'), false);
});

// ---------- validation ----------
test('mobile validation blocks fake numbers', () => {
  assert.equal(mobile.parse('98765 43210'), '9876543210');
  assert.equal(mobile.parse('+91 9876543210'), '9876543210');
  assert.equal(mobile.parse('09876543210'), '9876543210');
  assert.throws(() => mobile.parse('0000000000'));
  assert.throws(() => mobile.parse('12345'));
});

test('booking input requires fields per booking type', () => {
  const customer = { fullName: 'A', mobile: '9876543210', email: 'a@b.co', passengers: 1,
    pickupAddress: 'x', pickupDate: '2026-10-01', pickupTime: '9:00 AM' };
  assert.ok(bookingInput.safeParse({ bookingType: 'oneway', carType: 'SUV', pickup: 'Raipur', drop: 'Durg', customer }).success);
  assert.equal(bookingInput.safeParse({ bookingType: 'oneway', carType: 'SUV', pickup: 'Raipur', customer }).success, false);
  assert.equal(bookingInput.safeParse({ bookingType: 'round-trip', carType: 'SUV', pickup: 'Raipur', drop: 'Durg', customer }).success, false);
  assert.equal(bookingInput.safeParse({ bookingType: 'local-rental', carType: 'SUV', pickup: 'Raipur', customer }).success, false);
  assert.equal(bookingInput.safeParse({ bookingType: 'oneway', carType: 'SUV', pickup: 'Raipur', drop: 'Durg',
    customer: { ...customer, passengers: 8789212723 } }).success, false);
  assert.ok(enquiryInput.safeParse({ serviceType: 'oneway', pickup: 'Raipur', dropOrPackage: 'Durg', mobile: '9876543210' }).success);
});

// ---------- dates ----------
test('IST formatting', () => {
  const d = new Date('2026-09-24T20:00:00Z'); // 1:30 AM on 25 Sep IST
  assert.equal(istToday(d), '2026-09-25');
  assert.equal(istDate(d), '25/09/2026');
  assert.equal(istTime(d), '01:30 am');
  assert.equal(displayDate('2026-09-24', true), '24 Sep 2026');
});
