// Fake NIN (NUBAN KYC) and Paystack APIs for the LOCAL end-to-end stack only.
// The Edge Functions reach it at host.docker.internal; synthetic data only.
// NINs starting with 2 → Ada Nkem Obi (no phone); anything else → not found
// (tests use a random NIN per account: one NIN, one account). Accounts at bank 058:
// 0123456789 → ADA NKEM OBI (matches), 0987654321 → CHUKWUDI NWOSU (mismatch).
// Cloudflare Email Sending (Blueprint 13): each message the outbox worker
// sends is handed to the local mail catcher (Mailpit); nothing leaves the
// machine.
import { createServer } from 'node:http';

const mailpit = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
/** @param {import('node:http').IncomingMessage} req */
const readJson = async (req) => {
	const chunks = [];
	for await (const chunk of req) chunks.push(chunk);
	return JSON.parse(Buffer.concat(chunks).toString('utf8'));
};

const port = Number(process.argv[2] ?? 54399);
/** @param {import('node:http').ServerResponse} res @param {number} status @param {unknown} body */
const json = (res, status, body) => {
	res.writeHead(status, { 'content-type': 'application/json' });
	res.end(JSON.stringify(body));
};
/** @type {Record<string, string>} */
const accounts = {
	'0123456789': 'ADA NKEM OBI',
	1122334455: 'ADA NKEM OBI',
	'0987654321': 'CHUKWUDI NWOSU'
};

createServer(async (req, res) => {
	const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
	if (
		/^\/client\/v4\/accounts\/[^/]+\/email\/sending\/send$/.test(url.pathname) &&
		req.method === 'POST'
	) {
		if (req.headers.authorization !== 'Bearer e2e-local-email') {
			return json(res, 403, {
				success: false,
				errors: [{ code: 10000, message: 'Authentication error' }]
			});
		}
		const mail = await readJson(req);
		const relayed = await fetch(`${mailpit}/api/v1/send`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({
				From: { Email: mail.from.address, Name: mail.from.name },
				To: mail.to.map((/** @type {string} */ Email) => ({ Email })),
				Subject: mail.subject,
				HTML: mail.html,
				Text: mail.text,
				Headers: mail.headers
			})
		});
		if (!relayed.ok)
			return json(res, 503, { success: false, errors: [{ code: 1, message: 'catcher' }] });
		const { ID } = await relayed.json();
		return json(res, 200, {
			success: true,
			errors: [],
			messages: [],
			result: { delivered: mail.to, permanent_bounces: [], queued: [], message_id: `<${ID}@e2e>` }
		});
	}
	if (url.pathname === '/api/nin-data') {
		if ((url.searchParams.get('nin_no') ?? '').startsWith('2')) {
			return json(res, 200, {
				status: true,
				data: { firstname: 'ADA', middlename: 'NKEM', surname: 'OBI', telephoneno: '' }
			});
		}
		return json(res, 404, { status: false, message: 'NIN not found' });
	}
	// Turnstile siteverify (Blueprint 10), reached by the app server under
	// `vite preview`: any non-empty token passes, like Cloudflare's test secret.
	if (url.pathname === '/turnstile/v0/siteverify' && req.method === 'POST') {
		return json(res, 200, { success: true, hostname: 'example.com', action: '' });
	}
	if (url.pathname === '/bank') {
		return json(res, 200, {
			status: true,
			data: [{ name: 'Test Bank', code: '058', slug: 'test-bank', active: true, type: 'nuban' }],
			meta: { next: null }
		});
	}
	if (url.pathname === '/bank/resolve') {
		const number = url.searchParams.get('account_number') ?? '';
		const name = accounts[number];
		if (!name) return json(res, 422, { status: false, message: 'Could not resolve account name' });
		return json(res, 200, { status: true, data: { account_number: number, account_name: name } });
	}
	json(res, 404, { status: false });
}).listen(port, '0.0.0.0');
