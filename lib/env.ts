// All secrets come from Vercel -> Settings -> Environment Variables (or a local .env).
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

export const env = {
  get supabaseUrl() { return required('SUPABASE_URL'); },
  get supabaseSecretKey() { return required('SUPABASE_SECRET_KEY'); },
  get razorpayKeyId() { return required('RAZORPAY_KEY_ID'); },
  get razorpayKeySecret() { return required('RAZORPAY_KEY_SECRET'); },
  get razorpayWebhookSecret() { return required('RAZORPAY_WEBHOOK_SECRET'); },
  get msg91AuthKey() { return required('MSG91_AUTH_KEY'); },
  get allowedOrigins() {
    return (process.env.ALLOWED_ORIGINS ?? 'https://kitecab.com,https://www.kitecab.com')
      .split(',').map((o) => o.trim()).filter(Boolean);
  },
  /**
   * DEV/TEST ONLY: when set, every WhatsApp goes to this one number instead of
   * customers and admins. Leave empty in production.
   */
  get whatsappTestNumber(): string | undefined {
    const digits = (process.env.WHATSAPP_TEST_NUMBER ?? '').replace(/\D/g, '');
    if (!digits) return undefined;
    return digits.length === 10 ? `91${digits}` : digits;
  },
  /** Salt for hashing client IPs (rate limiting) so raw IPs are never stored. */
  get ipSalt() { return process.env.IP_HASH_SALT ?? 'kitecab'; },
};
