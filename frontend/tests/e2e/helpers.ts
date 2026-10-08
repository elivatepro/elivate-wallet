// E2E helpers. Talk only to the local stack: Mailpit for emails, the local
// Supabase API for the one setup step the UI does not offer yet (creating a
// network, which belongs to the later billing slice). Synthetic data only.

import { expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { createClient } from '@supabase/supabase-js';

const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
const SUPABASE_URL = process.env.SUPABASE_URL ?? '';
const PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY ?? '';

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

/**
 * Creates a pending-payment network for the person through the real Edge
 * Functions (POST /org/networks), in a separate Auth session of their own.
 */
export async function createNetworkFor(email: string, password: string, pin: string, name: string) {
	const supabase = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
		auth: { persistSession: false, autoRefreshToken: false }
	});
	const { data, error } = await supabase.auth.signInWithPassword({ email, password });
	if (error || !data.session) throw new Error('test sign-in failed');
	const call = async (fn: string, path: string, body: unknown) => {
		const response = await fetch(`${SUPABASE_URL}/functions/v1/${fn}${path}`, {
			method: 'POST',
			headers: {
				authorization: `Bearer ${data.session.access_token}`,
				apikey: PUBLISHABLE_KEY,
				'content-type': 'application/json'
			},
			body: JSON.stringify(body)
		});
		const json = (await response.json()) as { ok: boolean };
		if (!json.ok) throw new Error(`${fn}${path} failed: ${JSON.stringify(json)}`);
		return json;
	};
	await call('security', '/pin/verify', { pin });
	await call('org', '/networks', {
		name,
		shortName: name.split(' ')[0],
		idempotencyKey: crypto.randomUUID()
	});
	await supabase.auth.signOut({ scope: 'local' });
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
