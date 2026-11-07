/**
 * Runs the Vercel functions in api/ on http://localhost:3000 for local testing
 * (no Vercel login needed). Uses the keys in .env — the same database, Razorpay
 * and MSG91 account as configured there.
 *
 *   npx tsx scripts/local-api.mts
 *
 * Set WHATSAPP_TEST_NUMBER in .env to send every WhatsApp to one phone while testing.
 */
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

process.loadEnvFile?.('.env');
const PORT = Number(process.env.PORT ?? 3000);

type Handler = (req: unknown, res: unknown) => Promise<unknown>;
const cache = new Map<string, Promise<{ handler: Handler; raw: boolean }>>();

function load(route: string) {
  if (!cache.has(route)) {
    const file = pathToFileURL(path.resolve('api', `${route}.ts`)).href;
    cache.set(
      route,
      import(file).then((m) => {
        const mod = m.default?.default ? m.default : m;
        return { handler: mod.default as Handler, raw: mod.config?.api?.bodyParser === false };
      }),
    );
  }
  return cache.get(route)!;
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', `http://localhost:${PORT}`);
    const route = url.pathname.replace(/^\/api\//, '').replace(/\/$/, '');
    if (!url.pathname.startsWith('/api/') || !/^[a-z-]+(\/[a-z-]+)?$/.test(route)) {
      res.writeHead(404).end('Not found');
      return;
    }
    let mod: { handler: Handler; raw: boolean };
    try {
      mod = await load(route);
    } catch {
      res.writeHead(404).end('No such endpoint');
      return;
    }

    // Vercel-style request: parsed JSON body (unless the function reads the raw body itself).
    const vreq = req as http.IncomingMessage & { body?: unknown; query?: Record<string, string> };
    vreq.query = Object.fromEntries(url.searchParams);
    if (!mod.raw && req.method !== 'GET' && req.method !== 'OPTIONS') {
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      const text = Buffer.concat(chunks).toString('utf8');
      try {
        vreq.body = text ? JSON.parse(text) : {};
      } catch {
        vreq.body = text;
      }
    }

    // Vercel-style response helpers.
    const vres = res as http.ServerResponse & {
      status: (c: number) => typeof vres;
      json: (b: unknown) => typeof vres;
      send: (b: unknown) => typeof vres;
    };
    vres.status = (c) => ((vres.statusCode = c), vres);
    vres.json = (b) => {
      if (!vres.getHeader('Content-Type')) vres.setHeader('Content-Type', 'application/json');
      vres.end(JSON.stringify(b));
      return vres;
    };
    vres.send = (b) => (vres.end(typeof b === 'string' ? b : JSON.stringify(b)), vres);

    const started = Date.now();
    try {
      await mod.handler(vreq, vres);
    } catch (err) {
      console.error(err);
      if (!res.headersSent) res.writeHead(500).end('error');
    }
    console.log(`${req.method} ${url.pathname} → ${res.statusCode} (${Date.now() - started} ms)`);
  })
  .listen(PORT, () => console.log(`KiteCab API on http://localhost:${PORT}/api`));
