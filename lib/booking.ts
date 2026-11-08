import { db, must, type Settings } from './db';
import { istToday, packageLabel } from './format';
import { HttpError } from './http';
import { advanceFor, priceFor, roundTripFare, type RoundTripRate } from './pricing';
import { createPaymentLink } from './razorpay';
import type { BookingInput } from './validate';
import { adminBooking, customerBooking, sendWhatsApp, type BookingForMessage } from './whatsapp';

export interface Quote {
  fare: number;
  distanceKm: number | null;
  routeId: number | null;
  rentalPackageId: number | null;
  rentalPackage: string | null;
}

/** Works out the fare from the database. The price sent by the browser is never trusted. */
export async function quote(input: BookingInput): Promise<Quote> {
  if (input.bookingType === 'local-rental') {
    const [pkg, pickup] = await Promise.all([
      db().from('rental_packages').select('*').eq('id', input.rentalPackageId!).eq('is_active', true).maybeSingle(),
      db().from('locations').select('id').eq('name', input.pickup).eq('is_active', true).maybeSingle(),
    ]);
    if (!pkg.data) throw new HttpError(400, 'This rental package is not available.');
    if (!pickup.data) throw new HttpError(400, 'We do not serve this pickup location right now.');
    return {
      fare: priceFor(pkg.data, input.carType),
      distanceKm: pkg.data.km,
      routeId: null,
      rentalPackageId: pkg.data.id,
      rentalPackage: packageLabel(pkg.data.hours, pkg.data.km),
    };
  }

  const found = await db().from('route_fares').select('*')
    .eq('pickup', input.pickup).eq('drop', input.drop!).maybeSingle();
  if (found.error) throw new Error(`route lookup: ${found.error.message}`);
  const route = found.data;
  if (!route) throw new HttpError(400, 'No cabs are available for the selected locations.');

  if (input.bookingType === 'oneway') {
    return { fare: priceFor(route, input.carType), distanceKm: route.distance_km, routeId: route.id, rentalPackageId: null, rentalPackage: null };
  }

  const rate = (await db().from('round_trip_rates').select('*')
    .eq('waiting_slot', input.waitingTime!).eq('is_active', true).maybeSingle()).data as RoundTripRate | null;
  if (!rate) throw new HttpError(400, 'Please choose a valid waiting time.');
  return {
    fare: roundTripFare(rate, input.carType, input.approxDistanceKm!),
    distanceKm: route.distance_km,
    routeId: route.id,
    rentalPackageId: null,
    rentalPackage: null,
  };
}

export interface CreatedBooking {
  bookingId: number;
  fare: number;
  advanceAmount: number;
  /**
   * Already running: creates the Razorpay advance link, saves it and sends the WhatsApps.
   * The API replies before this finishes (pass it to waitUntil); the website then shows the
   * pay button as soon as the link exists (GET /api/pay-link).
   */
  afterReply: Promise<unknown>;
}

/** Saves the booking in one database call. `q` can be passed in when already calculated. */
export async function createBooking(input: BookingInput, settings: Settings, ipHash: string, q?: Quote): Promise<CreatedBooking> {
  if (!settings.booking_open) throw new HttpError(503, 'Online booking is paused. Please call or WhatsApp us.');

  const c = input.customer;
  const today = istToday();
  const maxDate = istToday(new Date(Date.now() + 366 * 86_400_000));
  if (c.pickupDate < today || c.pickupDate > maxDate) throw new HttpError(400, 'Please choose a valid pickup date.');

  const fare = q ?? (await quote(input));
  const advanceAmount = advanceFor(fare.fare, settings.advance_percent);

  const saved = await db().rpc('create_booking', {
    p_customer: { full_name: c.fullName, mobile: c.mobile, email: c.email },
    p_booking: {
      booking_type: input.bookingType,
      car_type: input.carType,
      pickup_location: input.pickup,
      drop_location: input.bookingType === 'local-rental' ? null : input.drop,
      route_id: fare.routeId,
      rental_package_id: fare.rentalPackageId,
      rental_package: fare.rentalPackage,
      waiting_time: input.waitingTime ?? null,
      approx_distance_km: input.approxDistanceKm ?? null,
      distance_km: fare.distanceKm,
      fare: fare.fare,
      advance_percent: settings.advance_percent,
      advance_amount: advanceAmount,
      customer_name: c.fullName,
      mobile: c.mobile,
      email: c.email,
      passengers: c.passengers,
      pickup_address: c.pickupAddress,
      pickup_date: c.pickupDate,
      pickup_time: c.pickupTime,
      ip_hash: ipHash,
    },
  });
  const booking = must(saved, 'save booking') as BookingForMessage;

  return {
    bookingId: booking.id,
    fare: fare.fare,
    advanceAmount,
    afterReply: preparePayment(booking, advanceAmount, settings),
  };
}

/** Razorpay link + payment row + booking WhatsApps. Never throws: the booking is already saved. */
async function preparePayment(booking: BookingForMessage, advanceAmount: number, settings: Settings): Promise<void> {
  let paymentLink: string | null = null;
  if (advanceAmount > 0) {
    try {
      const link = await createPaymentLink({
        bookingId: booking.id,
        amount: advanceAmount,
        customerName: booking.customer_name,
        mobile: booking.mobile,
        email: booking.email,
      });
      const row = await db().from('booking_payments').insert({
        booking_id: booking.id,
        customer_name: booking.customer_name,
        mobile: booking.mobile,
        booking_amount: booking.fare,
        advance_amount: advanceAmount,
        payment_type: 'ADVANCE',
        status: 'PENDING',
        payment_link: link.short_url,
        razorpay_payment_link_id: link.id,
        reference_id: `BOOKING_${booking.id}`,
      });
      if (row.error) console.error('save payment', row.error.message);
      else paymentLink = link.short_url;
    } catch (err) {
      console.error('payment link', err);
    }
  }
  await Promise.allSettled([
    sendWhatsApp(settings, adminBooking(settings, booking)),
    paymentLink ? sendWhatsApp(settings, customerBooking(booking, paymentLink)) : Promise.resolve(false),
  ]);
}
