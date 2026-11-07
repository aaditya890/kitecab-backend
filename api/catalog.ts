// GET /api/catalog — places, one-way fares, rental packages and round-trip rates
// for the website's booking form, straight from the database (so admin price
// changes and on/off switches show on the site within about a minute).
//
// Same compact shape as the frontend's static fallback /data/catalog.json.
// Cached on Vercel's CDN: one database read per minute at most, however many visitors.
import { db, must } from '../lib/db';
import { route } from '../lib/http';

type Row = { pickup: string; drop: string; distance_km: number; hatchback_price: number; sedan_price: number; suv_price: number };

async function allRouteFares(): Promise<Row[]> {
  const rows: Row[] = [];
  for (let from = 0; ; from += 1000) {
    const page = must(
      await db().from('route_fares')
        .select('pickup,drop,distance_km,hatchback_price,sedan_price,suv_price')
        .order('id')
        .range(from, from + 999),
      'load routes',
    ) as Row[];
    rows.push(...page);
    if (page.length < 1000) return rows;
  }
}

export default route({ methods: ['GET'], cors: true }, async (_req, res) => {
  const [routes, rentals, rates] = await Promise.all([
    allRouteFares(),
    db().from('rental_packages').select('id,hours,km,hatchback_price,sedan_price,suv_price').eq('is_active', true).order('hours'),
    db().from('round_trip_rates').select('*').eq('is_active', true).order('sort_order'),
  ]);

  const names = [...new Set(routes.flatMap((r) => [r.pickup, r.drop]))].sort((a, b) => a.localeCompare(b));
  const index = new Map(names.map((n, i) => [n, i]));

  res.setHeader('Cache-Control', 'public, max-age=60, s-maxage=60, stale-while-revalidate=600');
  res.json({
    generated: new Date().toISOString(),
    locations: names,
    routes: routes.map((r) => [index.get(r.pickup), index.get(r.drop), r.distance_km, r.hatchback_price, r.sedan_price, r.suv_price]),
    rentals: (must(rentals, 'load rentals') as { id: number; hours: number; km: number; hatchback_price: number; sedan_price: number; suv_price: number }[])
      .map((p) => ({ id: p.id, hours: p.hours, km: p.km, hatchback: p.hatchback_price, sedan: p.sedan_price, suv: p.suv_price })),
    roundTrip: (must(rates, 'load round trip rates') as Record<string, number & string>[]).map((r) => ({
      slot: r.waiting_slot,
      perKm: { Hatchback: r.hatchback_per_km, Sedan: r.sedan_per_km, SUV: r.suv_per_km },
      base: { Hatchback: r.hatchback_base, Sedan: r.sedan_base, SUV: r.suv_base },
    })),
  });
});
