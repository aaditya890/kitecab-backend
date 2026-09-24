import type { VercelRequest, VercelResponse } from '@vercel/node';
import { createHash } from 'node:crypto';
import { ZodError } from 'zod';
import { env } from './env';

/** Error with an HTTP status and a message that is safe to show the customer. */
export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

type Handler = (req: VercelRequest, res: VercelResponse) => Promise<unknown>;

interface RouteOptions {
  methods: string[];
  /** Browser-facing routes get CORS; server-to-server routes (webhooks) don't. */
  cors?: boolean;
}

/** Wraps a handler with CORS, method check and uniform error responses. */
export function route(options: RouteOptions, handler: Handler) {
  return async (req: VercelRequest, res: VercelResponse) => {
    if (options.cors) {
      const origin = req.headers.origin;
      if (origin && env.allowedOrigins.includes(origin)) {
        res.setHeader('Access-Control-Allow-Origin', origin);
        res.setHeader('Vary', 'Origin');
        res.setHeader('Access-Control-Allow-Methods', [...options.methods, 'OPTIONS'].join(','));
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
        res.setHeader('Access-Control-Max-Age', '86400');
      }
      if (req.method === 'OPTIONS') return res.status(204).end();
    }

    if (!options.methods.includes(req.method ?? '')) {
      return res.status(405).json({ ok: false, message: 'Method not allowed' });
    }

    try {
      await handler(req, res);
    } catch (err) {
      if (err instanceof HttpError) {
        return res.status(err.status).json({ ok: false, message: err.message });
      }
      if (err instanceof ZodError) {
        const first = err.issues[0];
        return res.status(400).json({
          ok: false,
          message: first ? `${first.path.join('.') || 'input'}: ${first.message}` : 'Invalid input',
        });
      }
      console.error(err);
      return res.status(500).json({ ok: false, message: 'Something went wrong. Please call us to book.' });
    }
  };
}

/** Client IP, hashed so it can be stored for rate limiting without keeping the raw IP. */
export function ipHash(req: VercelRequest): string {
  const forwarded = req.headers['x-forwarded-for'];
  const ip = (Array.isArray(forwarded) ? forwarded[0] : forwarded)?.split(',')[0]?.trim()
    ?? req.socket?.remoteAddress ?? 'unknown';
  return createHash('sha256').update(`${env.ipSalt}:${ip}`).digest('hex').slice(0, 32);
}

/** Reads the untouched request body (needed to verify webhook signatures). */
export async function readRawBody(req: VercelRequest): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  return Buffer.concat(chunks).toString('utf8');
}
