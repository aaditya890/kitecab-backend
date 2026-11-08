import { createHmac, timingSafeEqual } from 'node:crypto';
import { env } from './env';

/**
 * Short signed token that lets the browser that made a booking ask for its payment link
 * (GET /api/pay-link) without exposing other bookings.
 */
export function payToken(bookingId: number): string {
  return createHmac('sha256', env.ipSalt).update(`pay:${bookingId}`).digest('base64url').slice(0, 24);
}

export function validPayToken(bookingId: number, token: string): boolean {
  const expected = Buffer.from(payToken(bookingId));
  const given = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}
