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
  paymentLink: string | null;
  /** Background WhatsApp sends — pass to waitUntil() so the response isn't delayed. */
  notifications: Promise<unknown>;
}

export async function createBooking(input: BookingInput, settings: Settings, ipHash: string): Promise<CreatedBooking> {
  if (!settings.booking_open) throw new HttpError(503, 'Online booking is paused. Please call or WhatsApp us.');

  const c = input.customer;
  const today = istToday();
  const maxDate = istToday(new Date(Date.now() + 366 * 86_400_000));
  if (c.pickupDate < today || c.pickupDate > maxDate) throw new HttpError(400, 'Please choose a valid pickup date.');

  const q = await quote(input);
  const advanceAmount = advanceFor(q.fare, settings.advance_percent);

  const customer = must(
    await db().from('customers')
      .upsert({ full_name: c.fullName, mobile: c.mobile, email: c.email }, { onConflict: 'mobile' })
      .select('id').single(),
    'save customer',
  );

  const booking = must(
    await db().from('bookings').insert({
      booking_type: input.bookingType,
      car_type: input.carType,
      pickup_location: input.pickup,
      drop_location: input.bookingType === 'local-rental' ? null : input.drop,
      route_id: q.routeId,
      rental_package_id: q.rentalPackageId,
      rental_package: q.rentalPackage,
      waiting_time: input.waitingTime ?? null,
      approx_distance_km: input.approxDistanceKm ?? null,
      distance_km: q.distanceKm,
      fare: q.fare,
      advance_percent: settings.advance_percent,
      advance_amount: advanceAmount,
      customer_id: customer.id,
      customer_name: c.fullName,
      mobile: c.mobile,
      email: c.email,
      passengers: c.passengers,
      pickup_address: c.pickupAddress,
      pickup_date: c.pickupDate,
      pickup_time: c.pickupTime,
      ip_hash: ipHash,
    }).select('*').single(),
    'save booking',
  ) as BookingForMessage;

  // Payment link: if Razorpay is down the booking is still saved and admins are told.
  let paymentLink: string | null = null;
  if (advanceAmount > 0) {
    try {
      const link = await createPaymentLink({
        bookingId: booking.id, amount: advanceAmount, customerName: c.fullName, mobile: c.mobile, email: c.email,
      });
      paymentLink = link.short_url;
      const saved = await db().from('payments').insert({
        booking_id: booking.id,
        customer_name: c.fullName,
        mobile: c.mobile,
        booking_amount: q.fare,
        advance_amount: advanceAmount,
        payment_type: 'ADVANCE',
        status: 'PENDING',
        payment_link: link.short_url,
        razorpay_payment_link_id: link.id,
        reference_id: `BOOKING_${booking.id}`,
      });
      if (saved.error) console.error('save payment', saved.error.message);
    } catch (err) {
      console.error(err);
    }
  }

  const notifications = Promise.allSettled([
    sendWhatsApp(settings, adminBooking(settings, booking)),
    paymentLink ? sendWhatsApp(settings, customerBooking(booking, paymentLink)) : Promise.resolve(false),
  ]);

  return { bookingId: booking.id, fare: q.fare, advanceAmount, paymentLink, notifications };
}
