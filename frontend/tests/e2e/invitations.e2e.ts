// Accepting an invitation (W-02, W-03 owner decision 8): through the emailed
// join link, as a new person and as an existing account, and from the in-app
// "Invitations for you" list. Local stack only, synthetic data.

import { expect, test, type Page } from '@playwright/test';
import {
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	inviteMember,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

test.describe.configure({ mode: 'serial' });

async function newFounder(label: string) {
	const founder = { email: uniqueEmail(label), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, founder.password, founder.pin);
	return founder;
}

async function signIn(page: Page, email: string, password = PASSWORD) {
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(password);
	await page.getByRole('button', { name: 'Sign in' }).click();
}

async function verifyPin(page: Page) {
	await expect(page).toHaveURL(/\/pin(\?.*)?$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
}

test('new person: join link → verify email → password → accept → PIN → home', async ({ page }) => {
	const founder = await newFounder('founder-join');
	const invitee = uniqueEmail('invitee');
	const { joinPath } = await inviteMember(founder, 'Harbor Test Network', invitee);

	// 1. The link opens the masked bound email; the token leaves the address bar.
	await page.goto(joinPath);
	await expect(page.getByRole('heading', { name: 'Confirm your email' })).toBeVisible();
	await expect(page.getByText(`${invitee[0]}•••••@example.test`)).toBeVisible();
	expect(page.url()).toMatch(/\/join$/);
	await expectAccessible(page);

	// 2. Verify email: the server derives the address; Auth sends the link.
	await page.getByRole('button', { name: 'Verify email' }).click();
	await expect(page.getByRole('heading', { name: 'Check your inbox' })).toBeVisible();

	// 3. A new address gets a sign-up confirmation; Continue returns to /join.
	await page.goto(await confirmLinkFor(invitee, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page).toHaveURL(/\/join$/);
	await expect(page.getByRole('heading', { name: 'Choose a password' })).toBeVisible();
	await expect(page.getByText(invitee)).toBeVisible();
	await expectAccessible(page);
	await page.getByLabel('New password').fill('short');
	await page.getByRole('button', { name: 'Set password' }).click();
	await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
	await page.getByLabel('New password').fill(PASSWORD);
	await page.getByRole('button', { name: 'Set password' }).click();

	// 4. Accept while the gate is still pin_setup_required (Blueprint 03 Q7).
	await expect(page.getByRole('heading', { name: 'Accept your invitation' })).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Accept invitation' }).click();

	// 5. PIN next, then the only workspace opens.
	await expect(page).toHaveURL(/\/pin\/setup$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByText('Harbor Test Network').filter({ visible: true })).toBeVisible();
	expect(page.url()).not.toMatch(/token|#t=|[0-9a-f]{8}-[0-9a-f]{4}/i);

	// 6. The link is used up.
	await page.goto(joinPath);
	await expect(page.getByRole('heading', { name: 'Invitation unavailable' })).toBeVisible();

	// 7. The password set in step 3 signs in.
	await page.context().clearCookies();
	await signIn(page, invitee);
	await verifyPin(page);
	await expect(page).toHaveURL(/\/app$/);
});

test('existing account: join link → sign in → PIN → accept → home', async ({ page }) => {
	const founder = await newFounder('founder-existing');
	const invitee = uniqueEmail('existing');
	await createConfirmedAccount(invitee, PASSWORD, PIN);
	const { joinPath } = await inviteMember(founder, 'Delta Test Network', invitee);

	await page.goto(joinPath);
	await expect(page.getByRole('heading', { name: 'Confirm your email' })).toBeVisible();
	await page.getByRole('link', { name: 'Return to sign in' }).click();
	await signIn(page, invitee);
	await verifyPin(page);

	// The pending link continues after sign-in and PIN.
	await expect(page).toHaveURL(/\/join$/);
	await expect(page.getByRole('heading', { name: 'Accept your invitation' })).toBeVisible();
	await page.getByRole('button', { name: 'Accept invitation' }).click();
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByText('Delta Test Network').filter({ visible: true })).toBeVisible();
});

test('signed in as someone else: the invitation is refused, nothing joins', async ({ page }) => {
	const founder = await newFounder('founder-mismatch');
	const other = uniqueEmail('other');
	await createConfirmedAccount(other, PASSWORD, PIN);
	const { joinPath } = await inviteMember(founder, 'Cedar Test Network', uniqueEmail('intended'));

	await signIn(page, other);
	await verifyPin(page);
	await page.goto(joinPath);
	await expect(page.getByRole('heading', { name: 'Accept your invitation' })).toBeVisible();
	await page.getByRole('button', { name: 'Accept invitation' }).click();
	await expect(page.getByRole('alert')).toHaveText(
		'This invitation was sent to a different email. Sign in with that email, then open the link again.'
	);
	// The link is forgotten, so this account is not sent back to /join.
	await page.goto('/workspaces');
	await expect(page).toHaveURL(/\/workspaces$/);
});

test('in-app list: "Invitations for you" → Accept → home', async ({ page }) => {
	const founder = await newFounder('founder-list');
	const invitee = uniqueEmail('listed');
	await createConfirmedAccount(invitee, PASSWORD, PIN);
	await inviteMember(founder, 'Maple Test Network', invitee);

	await signIn(page, invitee);
	await verifyPin(page);
	await expect(page).toHaveURL(/\/workspaces$/);
	await expect(page.getByRole('heading', { name: 'Invitations for you' })).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Accept invitation to Maple Test Network' }).click();
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByText('Maple Test Network').filter({ visible: true })).toBeVisible();

	// Accepted invitations leave the list.
	await page.goto('/workspaces?switch');
	await expect(page.getByRole('heading', { name: 'Invitations for you' })).toHaveCount(0);
});

test('unknown or missing link: one unavailable page', async ({ page }) => {
	await page.goto(`/join#t=${'x'.repeat(43)}`);
	await expect(page.getByRole('heading', { name: 'Invitation unavailable' })).toBeVisible();
	expect(page.url()).toMatch(/\/join(\?\/claim)?$/);
	await page.goto('/join');
	await expect(page.getByRole('heading', { name: 'Invitation unavailable' })).toBeVisible();
});

test.describe('320 px, both themes', () => {
	test.use({ viewport: { width: 320, height: 720 } });

	for (const theme of ['dark', 'light'] as const) {
		test(`join pages in ${theme}`, async ({ page, context }) => {
			await context.addCookies([{ name: 'ew_theme', value: theme, url: 'http://127.0.0.1:3000' }]);
			const founder = await newFounder(`founder-a11y-${theme}`);
			const { joinPath } = await inviteMember(
				founder,
				'Willow Test Network',
				uniqueEmail(`a11y-${theme}`)
			);
			await page.goto(joinPath);
			await expect(page.getByRole('heading', { name: 'Confirm your email' })).toBeVisible();
			await expectNoHorizontalScroll(page);
			await expectAccessible(page);
			await page.goto('/join#t=unknown');
			await expect(page.getByRole('heading', { name: 'Invitation unavailable' })).toBeVisible();
			await expectNoHorizontalScroll(page);
			await expectAccessible(page);
		});
	}
});
