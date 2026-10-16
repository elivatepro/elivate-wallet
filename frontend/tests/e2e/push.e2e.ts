// Push notifications (Blueprint 42): the Profile & security switch (PN02)
// subscribes this browser for the signed-in session; income posted for the
// member queues a push with the bell item; the outbox worker encrypts it
// (RFC 8291, VAPID) and sends it to the fake push service, where it decrypts
// with the stand-in browser's keys into the Part A wording. Signing out ends
// push on the device; the same person signing in again gets it back by itself.
// Chromium has no push service here, so PushManager is a stand-in holding
// test keys. Local stack only; synthetic data.

import { createDecipheriv, createECDH, createHmac, randomBytes } from 'node:crypto';
import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	localSql,
	recordIncome,
	runOutboxWorker,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs } = walletPeople;
const FAKE = 'http://127.0.0.1:54399';

test.describe.configure({ mode: 'serial' });

/** A stand-in browser push subscription with real keys, kept across reloads. */
function browserKeys() {
	const ecdh = createECDH('prime256v1');
	ecdh.generateKeys();
	const auth = randomBytes(16);
	const id = `e2e-${randomBytes(9).toString('base64url')}`;
	return {
		id,
		ecdh,
		auth,
		stub: {
			endpoint: `https://fcm.googleapis.com/fcm/send/${id}`,
			p256dh: ecdh.getPublicKey().toString('base64url'),
			auth: auth.toString('base64url')
		}
	};
}

async function standInPush(page: Page, stub: { endpoint: string; p256dh: string; auth: string }) {
	await page.context().grantPermissions(['notifications']);
	await page.addInitScript((s) => {
		// Headless Chromium reports "denied" whatever the context allows.
		Object.defineProperty(Notification, 'permission', { get: () => 'granted' });
		Notification.requestPermission = async () => 'granted';
		const KEY = 'e2e:push-subscription';
		const make = (key: number[]) => ({
			endpoint: s.endpoint,
			expirationTime: null,
			options: { userVisibleOnly: true, applicationServerKey: new Uint8Array(key).buffer },
			toJSON: () => ({
				endpoint: s.endpoint,
				expirationTime: null,
				keys: { p256dh: s.p256dh, auth: s.auth }
			}),
			getKey: () => null,
			unsubscribe: async () => {
				localStorage.removeItem(KEY);
				return true;
			}
		});
		PushManager.prototype.subscribe = async function (options?: PushSubscriptionOptionsInit) {
			const raw = options?.applicationServerKey;
			const key =
				raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw as Uint8Array);
			localStorage.setItem(KEY, JSON.stringify([...key]));
			return make([...key]) as unknown as PushSubscription;
		};
		PushManager.prototype.getSubscription = async function () {
			const saved = localStorage.getItem(KEY);
			return saved ? (make(JSON.parse(saved)) as unknown as PushSubscription) : null;
		};
	}, stub);
}

/** RFC 8291 on the browser's side. */
function decrypt(body: Buffer, ecdh: ReturnType<typeof createECDH>, auth: Buffer): string {
	const hmac = (key: Buffer, data: Buffer) => createHmac('sha256', key).update(data).digest();
	const salt = body.subarray(0, 16);
	const idlen = body[20]!;
	const asPublic = body.subarray(21, 21 + idlen);
	const ciphertext = body.subarray(21 + idlen);
	const secret = ecdh.computeSecret(asPublic);
	const info = Buffer.concat([
		Buffer.from('WebPush: info\0'),
		ecdh.getPublicKey(),
		asPublic,
		Buffer.from([1])
	]);
	const ikm = hmac(hmac(auth, secret), info);
	const prk = hmac(salt, ikm);
	const cek = hmac(prk, Buffer.from('Content-Encoding: aes128gcm\0\x01')).subarray(0, 16);
	const nonce = hmac(prk, Buffer.from('Content-Encoding: nonce\0\x01')).subarray(0, 12);
	const decipher = createDecipheriv('aes-128-gcm', cek, nonce);
	decipher.setAuthTag(ciphertext.subarray(ciphertext.length - 16));
	const plain = Buffer.concat([decipher.update(ciphertext.subarray(0, -16)), decipher.final()]);
	expect(plain[plain.length - 1]).toBe(2);
	return plain.subarray(0, -1).toString('utf8');
}

interface Received {
	readonly headers: Record<string, string>;
	readonly body: string;
}

async function pushesFor(id: string): Promise<Received[]> {
	return (await (await fetch(`${FAKE}/e2e/push/${id}`)).json()) as Received[];
}

const subscriptions = (email: string) =>
	localSql(`select count(*) from notify.push_subscriptions s join auth.users u on u.id = s.user_id
	  where u.email = '${email}'`);

test('the switch subscribes this device; income posted arrives encrypted with its wording', async ({
	page
}) => {
	const founder = { email: uniqueEmail('pn-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('pn-m');
	await memberWithAccount(founder, 'Push Test Network', member);
	const keys = browserKeys();
	await standInPush(page, keys.stub);
	await signInAs(page, member);

	// PN02: Profile & security → Notifications, off at first.
	await page.goto('/app/account');
	const toggle = page.getByRole('switch', { name: 'Notifications on this computer' });
	await expect(toggle).toHaveAttribute('aria-checked', 'false');
	await expect(page.getByText('Money moving and things that need you')).toBeVisible();
	await expectAccessible(page);
	await toggle.click();
	await expect(toggle).toHaveAttribute('aria-checked', 'true');
	await shot(page, 'PN02-notifications-on');
	expect(subscriptions(member)).toBe('1');
	await page.reload();
	await expect(
		page.getByRole('switch', { name: 'Notifications on this computer' })
	).toHaveAttribute('aria-checked', 'true');

	// Income posted: one push job with the bell item; the worker sends it.
	await recordIncome(founder, member, '250000.00');
	let received: Received[] = [];
	await expect(async () => {
		await runOutboxWorker();
		received = await pushesFor(keys.id);
		expect(received.length).toBeGreaterThan(0);
	}).toPass({ timeout: 30_000 });
	const push = received[0]!;
	expect(push.headers['content-encoding']).toBe('aes128gcm');
	expect(push.headers.ttl).toBe('43200');
	expect(push.headers.urgency).toBe('normal');
	expect(push.headers.authorization).toMatch(/^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=B[\w-]{86}$/);
	const payload = JSON.parse(decrypt(Buffer.from(push.body, 'base64'), keys.ecdh, keys.auth)) as {
		v: number;
		title: string;
		body: string;
		path: string;
	};
	expect(payload).toMatchObject({
		v: 1,
		title: 'Income posted',
		body: '₦250,000.00, split across your pockets'
	});
	expect(payload.path).toMatch(/^\/app(\/|$)/);
	expect(JSON.stringify(payload)).not.toMatch(/Fiverr|INC-|@/);
	expect(
		localSql(`select j.status from notify.push_jobs j join notify.items i on i.id = j.item_id
		  join auth.users u on u.id = i.user_id where u.email = '${member}' and i.kind = 'money.income_posted'`)
	).toBe('sent');

	// Turning it off stops push for this device.
	await page.getByRole('switch', { name: 'Notifications on this computer' }).click();
	await expect(
		page.getByRole('switch', { name: 'Notifications on this computer' })
	).toHaveAttribute('aria-checked', 'false');
	expect(subscriptions(member)).toBe('0');
});

test('signing out ends push on the device; signing back in brings it back', async ({ page }) => {
	const founder = { email: uniqueEmail('pn-f2'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('pn-m2');
	await memberWithAccount(founder, 'Push Session Network', member);
	const keys = browserKeys();
	await standInPush(page, keys.stub);
	await signInAs(page, member);
	await page.goto('/app/account');
	await page.getByRole('switch', { name: 'Notifications on this computer' }).click();
	await expect(
		page.getByRole('switch', { name: 'Notifications on this computer' })
	).toHaveAttribute('aria-checked', 'true');
	expect(subscriptions(member)).toBe('1');

	await page.getByRole('button', { name: 'Account' }).click();
	await page.getByRole('menuitem', { name: 'Sign out' }).click();
	await expect(page).toHaveURL(/\/sign-in$/);
	expect(subscriptions(member)).toBe('0');

	await signInAs(page, member);
	await page.goto('/app/account');
	await expect(
		page.getByRole('switch', { name: 'Notifications on this computer' })
	).toHaveAttribute('aria-checked', 'true');
	expect(subscriptions(member)).toBe('1');
});
