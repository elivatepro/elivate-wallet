// E2E helpers. Talk only to the local stack: Mailpit for emails, the local
// Supabase API for setup steps the UI does not offer yet (creating and
// activating a network, offices, sending an invitation), and the local
// database container for the two things no API offers (registering a platform
// admin, reading an invitation's token id). Synthetic data only.

import { execFileSync } from 'node:child_process';
import { createHmac } from 'node:crypto';
import { expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { createClient } from '@supabase/supabase-js';

const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
const SUPABASE_URL = process.env.SUPABASE_URL ?? '';
const PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY ?? '';
const DB_CONTAINER = process.env.E2E_DB_CONTAINER ?? 'supabase_db_elivate-wallet';
const INVITATION_TOKEN_SECRET = process.env.INVITATION_TOKEN_SECRET ?? '';
const OUTBOX_WORKER_SECRET = process.env.OUTBOX_WORKER_SECRET ?? '';

export const uniqueEmail = (label: string) =>
	`e2e-${label}-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.test`;

interface MailpitSearch {
	messages: Array<{ ID: string; Subject: string }>;
}

/** Waits for the newest email to `to` and returns the /auth/confirm link in it. */
export async function confirmLinkFor(to: string, subject: RegExp): Promise<string> {
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const search = (await (
			await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`)
		).json()) as MailpitSearch;
		const message = search.messages.find((m) => subject.test(m.Subject));
		if (message) {
			const detail = (await (await fetch(`${MAILPIT}/api/v1/message/${message.ID}`)).json()) as {
				HTML: string;
			};
			const href = detail.HTML.match(/href="([^"]*\/auth\/confirm\?[^"]*)"/)?.[1];
			if (href) return href.replaceAll('&amp;', '&');
		}
		await new Promise((r) => setTimeout(r, 500));
	}
	throw new Error(`no email with subject ${subject} for ${to}`);
}

/** Runs one SQL statement in the LOCAL database container and returns its text output. */
export function localSql(sql: string): string {
	return execFileSync(
		'docker',
		['exec', DB_CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-tAc', sql],
		{ encoding: 'utf8' }
	).trim();
}

const key = () => crypto.randomUUID();

/** A signed-in API session for setup steps, with the PIN already verified. */
export async function apiSession(email: string, password: string, pin: string) {
	const supabase = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
		auth: { persistSession: false, autoRefreshToken: false }
	});
	const { data, error } = await supabase.auth.signInWithPassword({ email, password });
	if (error || !data.session) throw new Error('test sign-in failed');
	const token = data.session.access_token;
	const call = async <T = Record<string, unknown>>(
		fn: string,
		path: string,
		body?: unknown,
		membershipId?: string,
		method?: 'PATCH'
	): Promise<T> => {
		const headers: Record<string, string> = {
			authorization: `Bearer ${token}`,
			apikey: PUBLISHABLE_KEY
		};
		if (body !== undefined) headers['content-type'] = 'application/json';
		if (membershipId) headers['x-membership'] = membershipId;
		const response = await fetch(`${SUPABASE_URL}/functions/v1/${fn}${path}`, {
			method: method ?? (body === undefined ? 'GET' : 'POST'),
			headers,
			body: body === undefined ? undefined : JSON.stringify(body)
		});
		const json = (await response.json()) as { ok: boolean; data: T };
		if (!json.ok) throw new Error(`${fn}${path} failed: ${JSON.stringify(json)}`);
		return json.data;
	};
	await call('security', '/pin/verify', { pin });
	return {
		userId: data.user.id,
		sessionId: (
			JSON.parse(Buffer.from(token.split('.')[1] ?? '', 'base64url').toString()) as {
				session_id: string;
			}
		).session_id,
		call,
		close: () => supabase.auth.signOut({ scope: 'local' })
	};
}

/**
 * Starts a network for the person through the real Edge Functions (POST
 * /org/networks) on the founder's 7-day trial (Blueprint 16), so it opens at
 * once, in a separate Auth session of their own.
 */
export async function createNetworkFor(email: string, password: string, pin: string, name: string) {
	const api = await apiSession(email, password, pin);
	await api.call('org', '/networks', {
		name,
		shortName: name.split(' ')[0],
		planKey: 'band_400',
		trial: true,
		idempotencyKey: key()
	});
	await api.close();
}

/**
 * Founder setup for invitation tests: an active network (activated by the
 * founder after registering them as a local platform admin), a World Team
 * office they lead, and a member invitation for `inviteeEmail` into it.
 * Returns the emailed join link's path, rebuilt from the token id with the
 * run's INVITATION_TOKEN_SECRET exactly like the outbox worker does.
 */
export async function inviteMember(
	founder: { email: string; password: string; pin: string },
	network: string,
	inviteeEmail: string
): Promise<{ joinPath: string }> {
	const api = await apiSession(founder.email, founder.password, founder.pin);
	localSql(
		`insert into identity.platform_admins (user_id, grant_reason) values ('${api.userId}', 'e2e local stack')`
	);
	const started = await api.call<{ tenantId: string; membershipId: string }>('org', '/networks', {
		name: network,
		shortName: network.split(' ')[0],
		idempotencyKey: key()
	});
	await api.call('org', `/admin/tenants/${started.tenantId}/activate`, {
		reason: 'e2e local activation',
		idempotencyKey: key()
	});
	const { uid } = await api.call<{ uid: string }>('security', '/state');
	const office = await api.call<{ officeId: string }>(
		'org',
		'/offices',
		{
			type: 'world_team',
			name: `${network.split(' ')[0]} World Team`,
			leaderUids: [uid],
			idempotencyKey: key()
		},
		started.membershipId
	);
	const invitation = await api.call<{ invitationId: string }>(
		'invitations',
		'/',
		{ officeId: office.officeId, role: 'member', email: inviteeEmail, idempotencyKey: key() },
		started.membershipId
	);
	await api.close();
	return { joinPath: `/join#t=${invitationToken(invitation.invitationId)}` };
}

/** The current link token of an invitation (same derivation as _shared/invite_token.ts). */
export function invitationToken(invitationId: string): string {
	if (!/^[0-9a-f]{64}$/i.test(INVITATION_TOKEN_SECRET)) {
		throw new Error('INVITATION_TOKEN_SECRET is not set; run through scripts/e2e-local.sh');
	}
	const tokenId = localSql(`select token_id from org.invitations where id = '${invitationId}'`);
	return createHmac('sha256', Buffer.from(INVITATION_TOKEN_SECRET, 'hex'))
		.update(`inv:v1:${tokenId}`)
		.digest('base64url');
}

/** axe-core WCAG A/AA scan; no violations allowed. */
export async function expectAccessible(page: Page) {
	const results = await new AxeBuilder({ page })
		.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'])
		.analyze();
	expect(
		results.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`)
	).toEqual([]);
}

/** No horizontal overflow (P-06: checked at 320 px). */
export async function expectNoHorizontalScroll(page: Page) {
	const overflow = await page.evaluate(
		() => document.documentElement.scrollWidth - document.documentElement.clientWidth
	);
	expect(overflow).toBeLessThanOrEqual(0);
}

/**
 * A confirmed account with a PIN, made through the real Auth + security API
 * (sign-up, the emailed token_hash verified server-side, first PIN).
 */
export async function createConfirmedAccount(email: string, password: string, pin: string) {
	const supabase = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
		auth: { persistSession: false, autoRefreshToken: false }
	});
	const { error } = await supabase.auth.signUp({ email, password });
	if (error) throw new Error('test sign-up failed');
	const link = new URL(await confirmLinkFor(email, /Confirm your Elivate Wallet email/));
	const verified = await supabase.auth.verifyOtp({
		token_hash: link.searchParams.get('token_hash') ?? '',
		type: 'signup'
	});
	const token = verified.data.session?.access_token;
	if (verified.error || !token) throw new Error('test confirmation failed');
	const response = await fetch(`${SUPABASE_URL}/functions/v1/security/pin/set`, {
		method: 'POST',
		headers: {
			authorization: `Bearer ${token}`,
			apikey: PUBLISHABLE_KEY,
			'content-type': 'application/json'
		},
		body: JSON.stringify({ pin, pinConfirm: pin })
	});
	if (!((await response.json()) as { ok: boolean }).ok) throw new Error('test PIN setup failed');
	await supabase.auth.signOut({ scope: 'local' });
}

/** A NIN the fake provider verifies (starts with 2), unique per call. */
export const verifiableNin = () => `2${String(Math.floor(Math.random() * 1e10)).padStart(10, '0')}`;

/** 1×1 PNG for the profile photo step. */
export const TINY_PNG = Buffer.from(
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
	'base64'
);

/**
 * Drives the wizard from the NIN step through the profile step (identity,
 * details, photo, phone, rank). Leaves the page on whatever comes next.
 */
export async function completeIdentityAndProfile(page: Page) {
	await expect(page).toHaveURL(/\/onboarding\/identity$/);
	await page.getByLabel('National Identification Number').fill(verifiableNin());
	// "Verify NIN", or "Try again" after a failed check.
	await page.getByRole('button', { name: /^(Verify NIN|Try again)$/ }).click();
	await expect(page.getByRole('heading', { name: 'Is this you?' })).toBeVisible();
	await expect(page.getByText('Ada Nkem Obi')).toBeVisible();
	await page.getByRole('link', { name: 'Yes, that’s me' }).click();
	await expect(page.getByRole('heading', { name: 'Suit up your profile' })).toBeVisible();
	// The photo field exists only when R2 storage is bound (not under vite preview).
	const photo = page.getByLabel('Profile photo');
	if (await photo.count()) {
		await photo.setInputFiles({ name: 'me.png', mimeType: 'image/png', buffer: TINY_PNG });
	}
	await page.getByLabel('Phone number').fill('803 214 5678');
	await page.getByRole('button', { name: /Your rank/ }).click();
	await expect(page.getByRole('dialog', { name: 'Your rank' })).toBeVisible();
	await page.getByRole('listbox', { name: 'Rank' }).press('ArrowDown');
	await page.getByRole('button', { name: 'Set rank' }).click();
	await page.getByRole('button', { name: 'Continue' }).click();
}

/**
 * Records income for a member through the real api.record_income command,
 * as the founder (President Team), with a synthetic receipt record. Runs the
 * command in the local database with the founder's live session.
 */
export async function recordIncome(
	founder: { email: string; password: string; pin: string },
	memberEmail: string,
	amount = '1000.00',
	currency: 'NGN' | 'USD' = 'NGN'
) {
	const api = await apiSession(founder.email, founder.password, founder.pin);
	const workspaces = await api.call<Array<{ membershipId: string; role: string }>>(
		'org',
		'/workspaces'
	);
	const president = workspaces.find((w) => w.role === 'president_team_member')!.membershipId;
	const key = `e2e${crypto.randomUUID().replaceAll('-', '')}`;
	localSql(`do $$
declare
  target uuid := (select m.id from org.memberships m join auth.users u on u.id = m.user_id
                  where u.email = '${memberEmail}' and m.role = 'member' and m.status = 'active'
                    and m.tenant_id = (select tenant_id from org.memberships where id = '${president}') limit 1);
  evidence uuid;
begin
  evidence := (api.create_evidence_upload('${api.userId}', '${api.sessionId}', '${president}', target, '${key}',
    'receipt.pdf', 'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload('${api.userId}', '${api.sessionId}', '${president}', evidence, 1000,
    repeat('b', 64), 'application/pdf');
  perform api.record_income('${api.userId}', '${api.sessionId}', '${president}', target, '${currency}', '${amount}',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[evidence], '${key}');
end $$`);
	await api.close();
}

/** An account's public UID, read from the LOCAL database (setup only). */
export function uidOf(email: string): string {
	return localSql(
		`select a.uid from identity.accounts a join auth.users u on u.id = a.user_id where u.email = '${email.replaceAll("'", "''")}'`
	);
}

/**
 * Waits until the Turnstile widget has produced its token (Blueprint 10).
 * Local runs use Cloudflare's always-pass test keys, so this is quick, but a
 * submit before the token exists is (correctly) refused by the server.
 */
export async function humanReady(page: Page) {
	await expect(page.locator('input[name="cf-turnstile-response"]')).not.toHaveValue('', {
		timeout: 15_000
	});
}

/**
 * Fills a field once the page has settled. After the POST "Continue" on
 * /auth/confirm the password page can hydrate after Playwright typed into it
 * (seen in CI), which clears the value; waiting for the network to go idle
 * and re-checking the value avoids a silent empty submit.
 */
export async function fillSettled(page: Page, label: string, value: string) {
	await page.waitForLoadState('networkidle');
	const field = page.getByLabel(label);
	await expect(async () => {
		await field.fill(value);
		await expect(field).toHaveValue(value, { timeout: 1_000 });
	}).toPass({ timeout: 10_000 });
}

/**
 * The /join "Choose a password" step. On a slow runner the server-rendered
 * form can be filled before hydration resets it, which submits an empty
 * password; retry until the next step ("Accept invitation") shows.
 */
export async function setJoinPassword(page: Page, password: string) {
	const accept = page.getByRole('button', { name: 'Accept invitation' });
	await expect(async () => {
		if (await accept.isVisible()) return;
		await page.getByLabel('New password').fill(password, { timeout: 3_000 });
		await page.getByRole('button', { name: 'Set password' }).click({ timeout: 3_000 });
		await expect(accept).toBeVisible({ timeout: 5_000 });
	}).toPass({ timeout: 30_000 });
}

/**
 * Setup for evidence review (Blueprint 12): makes an existing confirmed
 * account a second President of the founder's network and assigns them as a
 * Financial Evidence Reviewer (W-11), so they can decide cases the founder
 * submitted.
 */
export async function addReviewer(
	founder: { email: string; password: string; pin: string },
	reviewerEmail: string
) {
	const api = await apiSession(founder.email, founder.password, founder.pin);
	const workspaces = await api.call<Array<{ membershipId: string; role: string }>>(
		'org',
		'/workspaces'
	);
	const president = workspaces.find((w) => w.role === 'president_team_member')!.membershipId;
	const uid = uidOf(reviewerEmail);
	localSql(`do $$
begin
  perform api.add_president('${api.userId}', '${api.sessionId}', '${president}', '${uid}', 'e2e reviewer', '${key()}');
  perform api.assign_reviewer('${api.userId}', '${api.sessionId}', '${president}',
    (select m.id from org.memberships m join auth.users u on u.id = m.user_id
     where u.email = '${reviewerEmail}' and m.role = 'president_team_member' and m.status = 'active'),
    'e2e reviewer', '${key()}');
end $$`);
	await api.close();
}

/** Saves a full-page screenshot when E2E_SHOTS names a folder (Paper comparison). */
export async function shot(page: Page, name: string) {
	const dir = process.env.E2E_SHOTS;
	if (!dir) return;
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${dir}/${name}.png`, fullPage: true });
}

// Money-flow people (Blueprints 11, 12): a member who joins by invitation with
// a payout account, and signing in as the founder's President workspace.
const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

async function joinAsNewMember(page: Page, joinPath: string, email: string) {
	await page.goto(joinPath);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await page.goto(await confirmLinkFor(email, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await setJoinPassword(page, PASSWORD);
	await page.getByRole('button', { name: 'Accept invitation' }).click();
	await page.getByRole('link', { name: 'Let’s begin' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();
	await completeIdentityAndProfile(page);
	await page.getByLabel('Bank').selectOption('058');
	await page.getByLabel('Account number').fill('0123456789');
	await page.getByRole('button', { name: 'Check account' }).click();
	await page.getByRole('button', { name: 'Save account' }).click();
	await page.getByRole('link', { name: 'Go to my wallet' }).click();
	await expect(page).toHaveURL(/\/app$/);
}

async function signInAs(page: Page, email: string) {
	await page.context().clearCookies();
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).not.toHaveURL(/\/pin(\?.*)?$/);
}

async function asPresident(page: Page, email: string, network: string) {
	await signInAs(page, email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: new RegExp(`${network}.*President Team`) }).click();
}

/**
 * The same member as joinAsNewMember, set up through the real Edge Functions
 * instead of the screens (invitation accepted, NIN verified by the fake
 * provider, profile, payout account). For tests where joining is only setup;
 * the join screens themselves are covered by onboarding/invitations/wallet.
 */
async function memberWithAccount(
	founder: { email: string; password: string; pin: string },
	network: string,
	email: string
) {
	const { joinPath } = await inviteMember(founder, network, email);
	const token = joinPath.split('#t=')[1] ?? '';
	await createConfirmedAccount(email, PASSWORD, PIN);
	const api = await apiSession(email, PASSWORD, PIN);
	await api.call('invitations', '/accept', { token, idempotencyKey: key() });
	await api.call('identity', '/nin/verify', { nin: verifiableNin() });
	await api.call(
		'identity',
		'/profile',
		{ phone: '+2348032145678', rank: 'Distributor', idempotencyKey: key() },
		undefined,
		'PATCH'
	);
	const workspaces = await api.call<Array<{ membershipId: string; role: string }>>(
		'org',
		'/workspaces'
	);
	const membership = workspaces.find((w) => w.role === 'member')!.membershipId;
	// The bank list is filled from the (fake) provider on first read, as the screen does.
	await api.call('payout', '/banks', undefined, membership);
	const lookup = await api.call<{ lookupId: string }>(
		'payout',
		'/lookups',
		{ bankCode: '058', accountNumber: '0123456789', idempotencyKey: key() },
		membership
	);
	await api.call(
		'payout',
		'/accounts',
		{ lookupId: lookup.lookupId, confirmed: true, idempotencyKey: key() },
		membership
	);
	await api.close();
}

export const walletPeople = {
	PASSWORD,
	PIN,
	joinAsNewMember,
	memberWithAccount,
	signInAs,
	asPresident
};

/**
 * Stands in for the payout-checker worker for ONE member's withdrawal: leases
 * that payout's queued check (never another test's, so files can run in
 * parallel) and reports a match, or a payment-date mismatch.
 */
export function finishCheck(memberEmail: string, outcome: 'match' | 'date-mismatch' = 'match') {
	const mismatch = outcome === 'date-mismatch';
	localSql(`do $$
declare
  token uuid := gen_random_uuid();
  check_id uuid;
  rev finance.payout_revisions;
  w finance.withdrawals;
  paid date;
begin
  select c.id into check_id from finance.payout_checks c
  join finance.payouts p on p.id = c.payout_id
  join finance.withdrawals wd on wd.id = p.withdrawal_id
  join auth.users u on u.id = wd.owner_user_id
  -- Only a check the real worker could claim now (api.claim_payout_checks).
  where u.email = '${memberEmail}' and c.status = 'queued' and c.next_attempt_at <= now()
  order by c.created_at desc limit 1;
  if check_id is null then
    raise exception 'no ready payout check for ${memberEmail}';
  end if;
  update finance.payout_checks
  set status = 'leased', lease_token = token, lease_expires_at = now() + interval '2 minutes',
      attempts = attempts + 1, next_attempt_at = null
  where id = check_id;
  select r.* into rev from finance.payout_checks c join finance.payout_revisions r on r.id = c.revision_id
  where c.id = check_id;
  select wd.* into w from finance.payouts p join finance.withdrawals wd on wd.id = p.withdrawal_id
  where p.id = rev.payout_id;
  paid := rev.paid_on - ${mismatch ? 1 : 0};
  perform api.finish_payout_check(check_id, token, '${mismatch ? 'mismatch' : 'match'}',
    jsonb_build_object('paymentDate', paid::text, 'receipt', jsonb_build_object(
      'amount', trim_scale(rev.amount)::text, 'currency', 'NGN', 'recipientAccount', '0123456789',
      'recipientName', w.account_name, 'transactionDate', paid::text,
      'paymentStatus', 'successful', 'confidence', 'high')),
    ${mismatch ? "array['paymentDate_mismatch']" : "'{}'::text[]"}, 'e2e-stub', 'strict-single-receipt-v1');
end $$`);
}

/**
 * Runs the outbox worker once, as pg_cron would (Blueprint 13). It sends
 * through the fake Cloudflare (fake-providers.mjs) into Mailpit.
 */
export async function runOutboxWorker(): Promise<{
	claimed: number;
	results?: Record<string, number>;
}> {
	const response = await fetch(`${SUPABASE_URL}/functions/v1/outbox-worker`, {
		method: 'POST',
		headers: {
			authorization: `Bearer ${OUTBOX_WORKER_SECRET}`,
			'content-type': 'application/json'
		},
		body: '{}'
	});
	const json = (await response.json()) as {
		ok: boolean;
		data: { configured: boolean; claimed: number; results?: Record<string, number> };
	};
	if (!json.ok || !json.data.configured) throw new Error(`outbox worker: ${JSON.stringify(json)}`);
	return json.data;
}

export interface CaughtMail {
	readonly ID: string;
	readonly Subject: string;
	readonly HTML: string;
	readonly Text: string;
}

/** Waits for an email to `to` whose subject matches, from the local mail catcher. */
export async function mailFor(to: string, subject: RegExp): Promise<CaughtMail> {
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const search = (await (
			await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`)
		).json()) as MailpitSearch;
		const message = search.messages.find((m) => subject.test(m.Subject));
		if (message)
			return (await (await fetch(`${MAILPIT}/api/v1/message/${message.ID}`)).json()) as CaughtMail;
		await runOutboxWorker();
		await new Promise((r) => setTimeout(r, 500));
	}
	throw new Error(`no email with subject ${subject} for ${to}`);
}
