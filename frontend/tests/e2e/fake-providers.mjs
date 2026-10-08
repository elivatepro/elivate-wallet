// Fake NIN (NUBAN KYC) and Paystack APIs for the LOCAL end-to-end stack only.
// The Edge Functions reach it at host.docker.internal; synthetic data only.
// NINs starting with 2 → Ada Nkem Obi (no phone); anything else → not found
// (tests use a random NIN per account: one NIN, one account). Accounts at bank 058:
// 0123456789 → ADA NKEM OBI (matches), 0987654321 → CHUKWUDI NWOSU (mismatch).
import { createServer } from 'node:http';

const port = Number(process.argv[2] ?? 54399);
/** @param {import('node:http').ServerResponse} res @param {number} status @param {unknown} body */
const json = (res, status, body) => {
	res.writeHead(status, { 'content-type': 'application/json' });
	res.end(JSON.stringify(body));
};
/** @type {Record<string, string>} */
const accounts = { '0123456789': 'ADA NKEM OBI', '0987654321': 'CHUKWUDI NWOSU' };

createServer((req, res) => {
	const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
	if (url.pathname === '/api/nin-data') {
		if ((url.searchParams.get('nin_no') ?? '').startsWith('2')) {
			return json(res, 200, {
				status: true,
				data: { firstname: 'ADA', middlename: 'NKEM', surname: 'OBI', telephoneno: '' }
			});
		}
		return json(res, 404, { status: false, message: 'NIN not found' });
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
