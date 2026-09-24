import { z } from 'zod';

const name = (max: number) => z.string().trim().min(1, 'is required').max(max);

/** Indian mobile: 10 digits starting 6-9 (blocks 0000000000 and typos). */
export const mobile = z.string().trim()
  .transform((v) => v.replace(/\D/g, '').replace(/^(91|0)(?=\d{10}$)/, ''))
  .pipe(z.string().regex(/^[6-9]\d{9}$/, 'enter a valid 10-digit mobile number'));

export const bookingType = z.enum(['oneway', 'round-trip', 'local-rental']);
export const carType = z.enum(['Hatchback', 'Sedan', 'SUV']);

export const enquiryInput = z.object({
  serviceType: bookingType,
  pickup: name(120),
  dropOrPackage: name(120),
  mobile,
});
export type EnquiryInput = z.infer<typeof enquiryInput>;

export const bookingInput = z.object({
  bookingType,
  carType,
  pickup: name(120),
  drop: name(120).optional(),                         // oneway, round-trip
  rentalPackageId: z.number().int().positive().optional(), // local-rental
  waitingTime: name(40).optional(),                   // round-trip
  approxDistanceKm: z.number().int().min(1).max(3000).optional(), // round-trip
  customer: z.object({
    fullName: name(80),
    mobile,
    email: z.string().trim().email('enter a valid email').max(120),
    passengers: z.number().int().min(1).max(20),
    pickupAddress: name(300),
    pickupDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'use YYYY-MM-DD'),
    pickupTime: name(20),
  }),
}).superRefine((b, ctx) => {
  const need = (field: keyof typeof b, message: string) => {
    if (b[field] === undefined) ctx.addIssue({ code: 'custom', path: [field], message });
  };
  if (b.bookingType === 'oneway') need('drop', 'is required');
  if (b.bookingType === 'round-trip') {
    need('drop', 'is required');
    need('waitingTime', 'is required');
    need('approxDistanceKm', 'is required');
  }
  if (b.bookingType === 'local-rental') need('rentalPackageId', 'is required');
});
export type BookingInput = z.infer<typeof bookingInput>;
