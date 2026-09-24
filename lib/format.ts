// Vercel runs in UTC; everything customer-facing is shown in India time.
const IST = 'Asia/Kolkata';

/** '24/09/2026' — same as the old admin_enquiry message. */
export function istDate(d = new Date()): string {
  return new Intl.DateTimeFormat('en-GB', { timeZone: IST, day: '2-digit', month: '2-digit', year: 'numeric' }).format(d);
}

/** '04:51 pm' — same as the old admin_enquiry message. */
export function istTime(d = new Date()): string {
  return new Intl.DateTimeFormat('en-IN', { timeZone: IST, hour: '2-digit', minute: '2-digit', hour12: true }).format(d);
}

/** Today's date in India as 'YYYY-MM-DD'. */
export function istToday(d = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: IST, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** 'YYYY-MM-DD' -> '24 Sep 2026' (withYear) or '24 Sep'. Fixed month names (ICU may say 'Sept'). */
export function displayDate(isoDate: string, withYear: boolean): string {
  const [y, m, d] = isoDate.split('-');
  const label = `${d} ${MONTHS[Number(m) - 1]}`;
  return withYear ? `${label} ${y}` : label;
}

/** Rental package label, e.g. '8hour 80km' (same wording as the legacy site). */
export function packageLabel(hours: number, km: number): string {
  return `${hours}hour ${km}km`;
}
