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
function localSql(sql: string): string {
	return execFileSync(
		'docker',
		['exec', DB_CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-tAc', sql],
		{ encoding: 'utf8' }
	).trim();
}

const key = () => crypto.randomUUID();

/** A signed-in API session for setup steps, with the PIN already verified. */
async function apiSession(email: string, password: string, pin: string) {
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
		membershipId?: string
	): Promise<T> => {
		const headers: Record<string, string> = {
			authorization: `Bearer ${token}`,
			apikey: PUBLISHABLE_KEY
		};
		if (body !== undefined) headers['content-type'] = 'application/json';
		if (membershipId) headers['x-membership'] = membershipId;
		const response = await fetch(`${SUPABASE_URL}/functions/v1/${fn}${path}`, {
			method: body === undefined ? 'GET' : 'POST',
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
 * Creates a pending-payment network for the person through the real Edge
 * Functions (POST /org/networks), in a separate Auth session of their own.
 */
export async function createNetworkFor(email: string, password: string, pin: string, name: string) {
	const api = await apiSession(email, password, pin);
	await api.call('org', '/networks', {
		name,
		shortName: name.split(' ')[0],
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
	amount = '1000.00'
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
                  where u.email = '${memberEmail}' and m.role = 'member' and m.status = 'active' limit 1);
  evidence uuid;
begin
  evidence := (api.create_evidence_upload('${api.userId}', '${api.sessionId}', '${president}', target, '${key}',
    'receipt.pdf', 'application/pdf', 1000, repeat('b', 64))->>'evidenceId')::uuid;
  perform api.finalize_evidence_upload('${api.userId}', '${api.sessionId}', '${president}', evidence, 1000,
    repeat('b', 64), 'application/pdf');
  perform api.record_income('${api.userId}', '${api.sessionId}', '${president}', target, 'NGN', '${amount}',
    'Fiverr', to_char(now() at time zone 'UTC', 'YYYY-MM-DD'), null, null, null, null, array[evidence], '${key}');
end $$`);
	await api.close();
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
