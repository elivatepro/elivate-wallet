// Workspace settings (Blueprint 17), against the local stack with synthetic
// people only. A President picks a team theme and saves it with the PIN
// (TS02d), members then see it, and an older revision comes back (F02); a
// backup is made by the real runner, downloaded with the PIN and a restore is
// requested and cancelled (E09, TS03d, V01–V04); ⌘K finds what the workspace
// can see (K01); unknown pages, no-access pages and Support (X01, X03, E11).
// E2E_SHOTS=<dir> keeps screenshots for review.

import type { Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	localSql,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const DESKTOP = { width: 1440, height: 900 };
const NARROW = { width: 320, height: 720 };
const SECRET = process.env.EXPORTS_WORKER_SECRET ?? '';

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

async function confirmWithPin(page: Page, button: string) {
	const dialog = page.getByRole('dialog');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: button }).click();
	await expect(dialog).toBeHidden();
}

async function runRunner(page: Page) {
	const response = await page.request.post('/internal/exports/run', {
		headers: { authorization: `Bearer ${SECRET}` },
		data: {}
	});
	expect(response.status()).toBe(200);
}

test('a President themes the network, members see it, and an older revision comes back', async ({
	page
}) => {
	const founder = { email: uniqueEmail('set-f'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('set-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Branding', member);

	await asPresident(page, founder.email, 'Cedar Branding');
	await page.setViewportSize(DESKTOP);
	await page.getByRole('link', { name: 'Settings', exact: true }).click();
	await expect(page).toHaveURL(/\/app\/settings$/);
	await expect(page.getByRole('heading', { name: 'What members see' })).toBeVisible();
	await expectAccessible(page);

	// Pick Cobalt; the preview follows before saving, the app only after.
	await page.getByRole('radio', { name: 'Cobalt' }).check();
	await expect(page.locator('.preview')).toHaveAttribute('data-team-theme', 'cobalt');
	await expect(page.locator('html')).not.toHaveAttribute('data-team-theme', 'cobalt');
	await page.getByLabel('Slogan').fill('Grow together, keep more');
	await page.getByRole('button', { name: 'Save changes' }).click();
	await confirmWithPin(page, 'Save changes');
	await expect(page.getByText(/Saved\. Members see the new look now/)).toBeVisible();
	await expect(page.locator('html')).toHaveAttribute('data-team-theme', 'cobalt');
	await shot(page, 'TS02d-branding-saved');

	// Team details: a support contact, with the same PIN window.
	await page.getByRole('link', { name: 'Team details' }).click();
	await page.getByLabel('Email').fill('help@cedar.example');
	await page.getByLabel('Phone').fill('0801 234 2210');
	await page.getByLabel('Help website').fill('http://help.cedar.example');
	await page.getByRole('button', { name: 'Save changes' }).click();
	await expect(page.getByText('Use an https:// address without a password in it.')).toBeVisible();
	await page.getByLabel('Help website').fill('https://help.cedar.example');
	await page.getByRole('button', { name: 'Save changes' }).click();
	await confirmWithPin(page, 'Save changes');
	await expect(page.getByText('Saved.')).toBeVisible();
	await expect(page.getByText('Support email changed + 2 more')).toBeVisible();
	await expect(page.getByText('Live')).toBeVisible();
	await shot(page, 'F02-details-saved');
	await page.setViewportSize(NARROW);
	await expectNoHorizontalScroll(page);
	await page.setViewportSize(DESKTOP);

	// A member sees the theme and their network's support contact.
	await signInAs(page, member);
	await expect(page.locator('html')).toHaveAttribute('data-team-theme', 'cobalt');
	await page.goto('/app/support');
	await expect(page.getByRole('heading', { name: 'How can we help?' })).toBeVisible();
	await expect(page.getByRole('link', { name: 'help@cedar.example' })).toBeVisible();
	await expect(page.getByRole('link', { name: 'support@elivatewallet.com' }).first()).toBeVisible();
	await expectAccessible(page);
	// No Chatwoot inbox locally: the page says so instead of pretending.
	await page.getByRole('button', { name: 'Start a chat' }).first().click();
	await expect(
		page.getByText(/Chat isn’t available right now|Chat isn't available right now/)
	).toBeVisible();
	await shot(page, 'E11-support');
	// Members never edit shared settings (W-20).
	const denied = await page.request.patch('/api/settings', {
		headers: { 'x-ew-workspace': 'x' },
		data: { expectedRevision: 1, fields: { theme: 'rose' }, idempotencyKey: 'k'.repeat(20) }
	});
	expect(denied.status()).toBeGreaterThanOrEqual(400);

	// Restore revision 1: Ember is back, as a new revision.
	await asPresident(page, founder.email, 'Cedar Branding');
	await page.goto('/app/settings/details');
	await page.getByRole('button', { name: 'Restore revision 1' }).click();
	await confirmWithPin(page, 'Restore');
	await expect(page.getByText('Restored revision 1.')).toBeVisible();
	await expect(page.locator('html')).not.toHaveAttribute('data-team-theme', /.+/);
	expect(
		localSql(`select count(*) from org.tenant_setting_revisions r join org.tenants t on t.id = r.tenant_id
			where t.name = 'Cedar Branding'`).trim()
	).toBe('4');
});

test('Back up now, download with the PIN, request a restore and cancel it', async ({ page }) => {
	const founder = { email: uniqueEmail('bk-f'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('bk-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Vault', member);

	await asPresident(page, founder.email, 'Cedar Vault');
	await page.setViewportSize(DESKTOP);
	await page.goto('/app/settings/backups');
	await expect(page.getByRole('heading', { name: 'No backups yet' })).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Back up now' }).click();
	await runRunner(page);
	await page.reload();
	await expect(page.getByText('Complete').first()).toBeVisible({ timeout: 30_000 });
	await expect(page.getByText(/records · .*encrypted/)).toBeVisible();
	await shot(page, 'E09-vault');

	const download = page.waitForEvent('download');
	await page.getByRole('button', { name: 'Download latest' }).click();
	await confirmWithPin(page, 'Download');
	const file = await (await download).path();
	const { readFileSync } = await import('node:fs');
	const bytes = readFileSync(file);
	expect(bytes.subarray(0, 2).toString()).toBe('PK');
	expect(bytes.includes(Buffer.from('manifest.json'))).toBe(true);
	expect(bytes.includes(Buffer.from('people.ndjson'))).toBe(true);
	expect(
		localSql(`select count(*) from audit.tenant_events e join org.tenants t on t.id = e.tenant_id
			where t.name = 'Cedar Vault' and e.action = 'backup.downloaded'`).trim()
	).toBe('1');

	await page.getByRole('link', { name: 'Request a restore' }).click();
	await expect(page.getByRole('heading', { name: 'Request a restore' })).toBeVisible();
	await page.getByLabel('Reason').fill('Too short');
	await page.getByRole('button', { name: 'Send request' }).click();
	await expect(page.getByText('Say why in 10 to 500 characters.')).toBeVisible();
	await page
		.getByLabel('Reason')
		.fill('Team settings were changed by mistake. Compare with this backup.');
	await page.getByRole('button', { name: 'Send request' }).click();
	await expect(page.getByRole('heading', { name: 'Restore request sent' })).toBeVisible();
	await expect(page.getByText(/^RST-[0-9A-Z]{4}-[0-9A-Z]{4}$/)).toBeVisible();
	await shot(page, 'V03-restore-sent');

	await page.getByRole('link', { name: 'Back to backup vault' }).click();
	await page.getByRole('button', { name: 'Cancel', exact: true }).click();
	await page.getByRole('dialog').getByRole('button', { name: 'Cancel request' }).click();
	await expect(page.getByText('Cancelled')).toBeVisible();
	await shot(page, 'TS03d-restore-cancelled');
});

test('⌘K finds people and offices in reach; unknown and closed pages say so', async ({ page }) => {
	const founder = { email: uniqueEmail('qs-f'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('qs-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Search', member);
	const memberUid = localSql(
		`select a.uid from identity.accounts a join auth.users u on u.id = a.user_id where u.email = '${member}'`
	).trim();

	await asPresident(page, founder.email, 'Cedar Search');
	await page.setViewportSize(DESKTOP);
	// The shortcut works once the workspace has loaded. The test browser reports
	// Windows ("Desktop Chrome"), so it is Ctrl+K there (⌘K on a Mac).
	await expect(page.getByRole('link', { name: 'Settings', exact: true })).toBeVisible();
	await page.keyboard.press('Control+k');
	const search = page.getByRole('combobox', {
		name: 'Search people, offices, references and pages'
	});
	await expect(search).toBeFocused();
	await search.fill(memberUid);
	await expect(page.getByRole('option', { name: new RegExp(memberUid) })).toBeVisible();
	await shot(page, 'K01-quick-search');
	await search.press('Enter');
	await expect(page).toHaveURL(/\/app\/members\/[0-9a-f-]{36}$/);

	await page.keyboard.press('Control+k');
	await search.fill('billing');
	await expect(page.getByRole('option', { name: /Billing/ })).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(search).toBeHidden();

	await page.goto('/app/no-such-page');
	await expect(page.getByRole('heading', { name: 'This page isn’t on the map' })).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'X01-not-found');

	// A member's search never reaches leadership records or other people.
	await signInAs(page, member);
	await expect(page.getByRole('button', { name: 'Quick search…' })).toBeVisible();
	await page.getByRole('button', { name: 'Quick search…' }).click();
	await search.fill(founder.email.slice(0, 6));
	await expect(
		page
			.getByRole('dialog')
			.getByText(/^No matches for/)
			.last()
	).toBeVisible();
	await page.keyboard.press('Escape');
	await page.goto('/app/queue');
	await expect(page.getByRole('heading', { name: 'You don’t have access' })).toBeVisible();
	await shot(page, 'X03-no-access');
});
