// Fare rules. Pure functions (no DB) so they are easy to test and to reuse.

export type CarType = 'Hatchback' | 'Sedan' | 'SUV';
export type BookingType = 'oneway' | 'round-trip' | 'local-rental';

export const CAR_TYPES: CarType[] = ['Hatchback', 'Sedan', 'SUV'];

export interface CarPrices {
  hatchback_price: number;
  sedan_price: number;
  suv_price: number;
}

export interface RoundTripRate {
  waiting_slot: string;
  hatchback_per_km: number; sedan_per_km: number; suv_per_km: number;
  hatchback_base: number;   sedan_base: number;   suv_base: number;
}

/** Route or rental package price for a car type. */
export function priceFor(prices: CarPrices, car: CarType): number {
  switch (car) {
    case 'Hatchback': return prices.hatchback_price;
    case 'Sedan': return prices.sedan_price;
    case 'SUV': return prices.suv_price;
  }
}

/** Round trip = per-km rate x approx km + base for the waiting slot. */
export function roundTripFare(rate: RoundTripRate, car: CarType, approxKm: number): number {
  switch (car) {
    case 'Hatchback': return rate.hatchback_per_km * approxKm + rate.hatchback_base;
    case 'Sedan': return rate.sedan_per_km * approxKm + rate.sedan_base;
    case 'SUV': return rate.suv_per_km * approxKm + rate.suv_base;
  }
}

/** Advance amount in whole rupees (same rounding as the legacy API). */
export function advanceFor(fare: number, percent: number): number {
  return Math.round((fare * percent) / 100);
}
