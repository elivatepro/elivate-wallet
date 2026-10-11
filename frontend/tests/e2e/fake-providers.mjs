// Fake NIN (NUBAN KYC) and Paystack APIs for the LOCAL end-to-end stack only.
// The Edge Functions reach it at host.docker.internal; synthetic data only.
// NINs starting with 2 → Ada Nkem Obi (no phone); anything else → not found
// (tests use a random NIN per account: one NIN, one account). Accounts at bank 058:
// 0123456789 → ADA NKEM OBI (matches), 0987654321 → CHUKWUDI NWOSU (mismatch).
// Cloudflare Email Sending (Blueprint 13): each message the outbox worker
// sends is handed to the local mail catcher (Mailpit); nothing leaves the
// machine.
// Paystack plan purchases (Blueprint 16): initialize returns a local "hosted
// checkout" page; paying there marks the transaction successful, posts a
// signed charge.success webhook to the local billing function and sends the
// payer back. Verify answers from the same store. Synthetic data only.
import { createHmac } from 'node:crypto';
import { createServer } from 'node:http';

const mailpit = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
/** @param {import('node:http').IncomingMessage} req */
const readJson = async (req) => {
	const chunks = [];
	for await (const chunk of req) chunks.push(chunk);
	return JSON.parse(Buffer.concat(chunks).toString('utf8'));
};

const port = Number(process.argv[2] ?? 54399);
const paystackKey = process.env.PAYSTACK_SECRET_KEY ?? '';
const billingWebhook = process.env.BILLING_WEBHOOK_URL ?? '';
/** @type {Map<string, {id: number, amount: number, email: string, callback: string, status: string, paidAt: string | null}>} */
const transactions = new Map();
let nextId = 5000;
let nextCode = 1;
/** @type {Map<string, number>} plan code → amount (kobo) */
const plans = new Map();
/** @type {Array<{customer: string, code: string, token: string, amount: number, next: string, status: string}>} */
const subscriptions = [];
/** @param {import('node:http').IncomingMessage} req */
const readForm = async (req) => {
	const chunks = [];
	for await (const chunk of req) chunks.push(chunk);
	return new URLSearchParams(Buffer.concat(chunks).toString('utf8'));
};
/** @param {string} reference */
const verified = (reference) => {
	const tx = transactions.get(reference);
	if (!tx) return null;
	return {
		id: tx.id,
		status: tx.status,
		reference,
		amount: tx.amount,
		currency: 'NGN',
		domain: 'test',
		paid_at: tx.paidAt,
		customer: { customer_code: 'CUS_e2elocal0001', email: tx.email },
		authorization: { reusable: true, channel: 'card', last4: '4081' },
		plan: null
	};
};
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
			// Blueprint 24: enough banks for the bank picker's search; only 058
			// resolves accounts.
			data: [
				['Access Bank', '044'],
				['Ecobank Nigeria', '050'],
				['Fidelity Bank', '070'],
				['First Bank of Nigeria', '011'],
				['Polaris Bank', '076'],
				['Sterling Bank', '232'],
				['Test Bank', '058'],
				['United Bank For Africa', '033'],
				['Wema Bank', '035'],
				['Zenith Bank', '057']
			].map(([name = '', code = '']) => ({
				name,
				code,
				slug: name.toLowerCase().replaceAll(' ', '-'),
				active: true,
				type: 'nuban'
			})),
			meta: { next: null }
		});
	}
	if (url.pathname === '/bank/resolve') {
		const number = url.searchParams.get('account_number') ?? '';
		const name = accounts[number];
		if (!name) return json(res, 422, { status: false, message: 'Could not resolve account name' });
		return json(res, 200, { status: true, data: { account_number: number, account_name: name } });
	}
	if (url.pathname === '/transaction/initialize' && req.method === 'POST') {
		const body = await readJson(req);
		const id = nextId++;
		transactions.set(body.reference, {
			id,
			amount: body.amount,
			email: body.email,
			callback: body.callback_url,
			status: 'abandoned',
			paidAt: null
		});
		return json(res, 200, {
			status: true,
			data: {
				authorization_url: `http://127.0.0.1:${port}/checkout/${body.reference}`,
				access_code: `ac_${id}`,
				reference: body.reference
			}
		});
	}
	const verify = url.pathname.match(/^\/transaction\/verify\/([A-Za-z0-9._=-]+)$/);
	if (verify && req.method === 'GET') {
		const data = verified(verify[1] ?? '');
		return data
			? json(res, 200, { status: true, data })
			: json(res, 400, { status: false, message: 'Transaction reference not found' });
	}
	const checkout = url.pathname.match(/^\/checkout\/([A-Za-z0-9._=-]+)(\/pay|\/cancel)?$/);
	if (checkout) {
		const reference = checkout[1] ?? '';
		const tx = transactions.get(reference);
		if (!tx) return json(res, 404, { status: false });
		if (!checkout[2]) {
			res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
			return res.end(`<!doctype html><title>Paystack (test)</title><main style="font:16px system-ui;padding:40px">
<h1>Paystack test checkout</h1><p>Pay NGN ${(tx.amount / 100).toFixed(2)}</p>
<form method="post" action="/checkout/${reference}/pay"><button>Pay</button></form>
<form method="post" action="/checkout/${reference}/cancel"><button>Cancel payment</button></form></main>`);
		}
		await readForm(req);
		if (checkout[2] === '/pay') {
			tx.status = 'success';
			tx.paidAt = new Date().toISOString();
			const raw = JSON.stringify({ event: 'charge.success', data: verified(reference) });
			const signature = createHmac('sha512', paystackKey).update(raw).digest('hex');
			await fetch(billingWebhook, {
				method: 'POST',
				headers: { 'content-type': 'application/json', 'x-paystack-signature': signature },
				body: raw
			}).catch(() => undefined);
		} else {
			tx.status = 'abandoned';
		}
		res.writeHead(303, { location: `${tx.callback}?trxref=${reference}&reference=${reference}` });
		return res.end();
	}
	if (url.pathname === '/plan' && req.method === 'POST') {
		const body = await readJson(req);
		const code = `PLN_e2e${nextCode++}`;
		plans.set(code, body.amount);
		return json(res, 200, { status: true, data: { plan_code: code } });
	}
	if (url.pathname === '/subscription' && req.method === 'POST') {
		const body = await readJson(req);
		const sub = {
			customer: body.customer,
			code: `SUB_e2e${nextCode++}`,
			token: `tok${nextCode}`,
			amount: plans.get(body.plan) ?? 0,
			next: body.start_date,
			status: 'active'
		};
		subscriptions.push(sub);
		return json(res, 200, {
			status: true,
			data: { subscription_code: sub.code, email_token: sub.token }
		});
	}
	const customer = url.pathname.match(/^\/customer\/(CUS_[A-Za-z0-9]+)$/);
	if (customer && req.method === 'GET') {
		return json(res, 200, {
			status: true,
			data: {
				customer_code: customer[1],
				subscriptions: subscriptions
					.filter((sub) => sub.customer === customer[1])
					.map((sub) => ({
						subscription_code: sub.code,
						email_token: sub.token,
						amount: sub.amount,
						next_payment_date: sub.next,
						status: sub.status
					}))
			}
		});
	}
	if (url.pathname === '/subscription/disable' && req.method === 'POST') {
		const body = await readJson(req);
		for (const sub of subscriptions) if (sub.code === body.code) sub.status = 'cancelled';
		return json(res, 200, { status: true, message: 'Subscription disabled successfully' });
	}
	json(res, 404, { status: false });
}).listen(port, '0.0.0.0');
