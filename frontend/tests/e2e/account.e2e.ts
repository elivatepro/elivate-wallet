// Account and security (Blueprint 10): forgot password through the Recovery
// email, change PIN, devices & sessions, Turnstile on the auth forms.
// Local stack only (Mailpit), synthetic data.

import { type Page } from '@playwright/test';
import { expect, stubTurnstile, test } from './fixtures';
import { createClient } from '@supabase/supabase-js';
import {
	completeIdentityAndProfile,
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	humanReady,
	inviteMember,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const NEW_PASSWORD = 'staple-lantern-violet';
const PIN = '1357';
const NEW_PIN = '2468';

test.describe.configure({ mode: 'serial' });

async function signIn(page: Page, email: string, password: string, pin: string) {
	await page.context().clearCookies();
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(password);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(pin);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).not.toHaveURL(/\/pin(\?.*)?$/);
}

test('auth forms carry the Turnstile widget and refuse a missing token', async ({ page }) => {
	for (const path of ['/sign-in', '/sign-up', '/forgot-password']) {
		await page.goto(path);
		await humanReady(page);
	}
	// A POST without a token is refused before Auth is called.
	const response = await page.request.post('/forgot-password', {
		form: { email: 'nobody@example.test' },
		headers: { origin: 'http://127.0.0.1:3000', 'x-sveltekit-action': 'true' }
	});
	expect(await response.text()).toContain('Complete the security check');
});

test('forgot password → Recovery email → new password → PIN', async ({ page }) => {
	const email = uniqueEmail('recover');
	await createConfirmedAccount(email, PASSWORD, PIN);

	await page.goto('/sign-in');
	await page.getByRole('link', { name: 'Forgot password?' }).click();
	await expect(page).toHaveURL(/\/forgot-password$/);
	await expectAccessible(page);
	await page.getByLabel('Email address').fill(email);
	await humanReady(page);
	await page.getByRole('button', { name: 'Send reset instructions' }).click();
	await expect(page.getByRole('heading', { name: 'Check for next steps' })).toBeVisible();

	// The Recovery template links to /auth/confirm with a token_hash (GET does not consume it).
	const link = await confirmLinkFor(email, /Reset your Elivate Wallet password/);
	expect(link).toContain('type=recovery');
	await page.goto(link);
	await expect(page.getByRole('heading', { name: 'Reset your password' })).toBeVisible();
	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page).toHaveURL(/\/reset-password$/);
	await page.getByLabel('New password').fill('short');
	await page.getByRole('button', { name: 'Save new password' }).click();
	await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
	await page.getByLabel('New password').fill(NEW_PASSWORD);
	await page.getByRole('button', { name: 'Save new password' }).click();
	// PIN as usual after a recovery.
	await expect(page).toHaveURL(/\/pin(\?.*)?$/);

	// The new password works, the old one does not.
	const supabase = createClient(
		process.env.SUPABASE_URL ?? '',
		process.env.SUPABASE_PUBLISHABLE_KEY ?? '',
		{
			auth: { persistSession: false, autoRefreshToken: false }
		}
	);
	expect(
		(await supabase.auth.signInWithPassword({ email, password: PASSWORD })).error
	).not.toBeNull();
	expect(
		(await supabase.auth.signInWithPassword({ email, password: NEW_PASSWORD })).error
	).toBeNull();
	await supabase.auth.signOut({ scope: 'local' });

	// The reset page is not reachable without a confirmed Recovery link.
	await page.goto('/reset-password');
	await expect(page).not.toHaveURL(/\/reset-password$/);
});

test('Profile & security: change PIN, devices and profile edit', async ({ page, browser }) => {
	const founder = { email: uniqueEmail('acct-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('acct-m');
	const { joinPath } = await inviteMember(founder, 'Account Test Network', member);

	// The member joins and finishes the wizard (the shell needs a workspace).
	await page.goto(joinPath);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await page.goto(await confirmLinkFor(member, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await page.getByLabel('New password').fill(PASSWORD);
	await page.getByRole('button', { name: 'Set password' }).click();
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

	// A second device, signed in and unlocked.
	const other = await browser.newContext();
	await stubTurnstile(other);
	const otherPage = await other.newPage();
	await signIn(otherPage, member, PASSWORD, PIN);

	await page.goto('/app/account');
	await expect(page.getByRole('heading', { level: 1, name: /^Ada/ })).toBeVisible();
	await expect(page.getByText('This device').first()).toBeVisible();
	// The browser's device is recorded, not the app server's.
	await expect(page.getByText(/· Chrome$/).first()).toBeVisible();
	await expectAccessible(page);

	// Change PIN: a wrong current PIN costs an attempt; then the change works.
	await page.goto('/app/account/pin');
	await page.getByLabel('Current PIN').fill('9999');
	await page.getByLabel('New PIN', { exact: true }).fill(NEW_PIN);
	await page.getByLabel('Confirm new PIN').fill(NEW_PIN);
	await page.getByRole('button', { name: 'Save new PIN' }).click();
	await expect(page.getByText('That PIN is incorrect. 4 tries left.')).toBeVisible();
	await page.getByLabel('Current PIN').fill(PIN);
	await page.getByLabel('New PIN', { exact: true }).fill(NEW_PIN);
	await page.getByLabel('Confirm new PIN').fill(NEW_PIN);
	await page.getByRole('button', { name: 'Save new PIN' }).click();
	await expect(page.getByText('Your PIN is changed.')).toBeVisible();

	// The other device must enter the PIN again.
	await otherPage.goto('/workspaces');
	await expect(otherPage).toHaveURL(/\/pin(\?.*)?$/);

	// Devices: sign out all others; the other device is signed out.
	await page.goto('/app/account/devices');
	await expect(
		page.getByRole('heading', { name: /signed-in devices|Devices & sessions/ })
	).toBeVisible();
	await page.getByRole('button', { name: 'Sign out all others' }).first().click();
	// Z07: confirm, no PIN.
	const confirmOut = page.getByRole('dialog', { name: 'Sign out 1 other device?' });
	await expect(confirmOut.getByText('This device stays signed in')).toBeVisible();
	await confirmOut.getByRole('button', { name: 'Sign out others' }).click();
	await expect(page.getByText('Signed out 1 device.')).toBeVisible();
	await otherPage.goto('/workspaces');
	await expect(otherPage).toHaveURL(/\/sign-in$/);
	await other.close();

	// Edit profile (Z04): display name and rank; the legal name is locked.
	await page.goto('/app/account');
	await page.getByRole('button', { name: 'Edit' }).click();
	const edit = page.getByRole('dialog', { name: 'Edit profile' });
	await expect(edit.getByText('From your NIN')).toBeVisible();
	await edit.getByLabel('Display name').fill('Ada Test');
	await edit.getByLabel('Rank').selectOption('Director');
	await edit.getByRole('button', { name: 'Save changes' }).click();
	await expect(edit).toHaveCount(0);
	await expect(page.getByRole('heading', { level: 1, name: 'Ada Test' })).toBeVisible();
	await expect(page.getByText('Director').first()).toBeVisible();

	// Replace the payout account (Z05): reason + PIN, then the new lookup.
	await page.goto('/app/payout-accounts');
	await page.getByRole('button', { name: 'Options for Test Bank •• 6789' }).click();
	await page.getByRole('menuitem', { name: 'Replace account' }).click();
	const replace = page.getByRole('dialog', { name: 'Replace Test Bank •• 6789' });
	await replace.getByLabel('Reason').fill('I closed this account with the bank');
	await replace.getByLabel('Your PIN').fill(NEW_PIN);
	await replace.getByRole('button', { name: 'Continue' }).click();
	await expect(page.getByRole('heading', { name: 'Replace bank account' })).toBeVisible();
	await page.getByLabel('Bank').selectOption('058');
	await page.getByLabel('Account number').fill('1122334455');
	await page.getByRole('button', { name: 'Check account' }).click();
	await page.getByRole('button', { name: 'Replace account' }).click();
	await expect(page).toHaveURL(/\/app\/payout-accounts$/);
	await expect(page.getByText('Test Bank •• 4455').first()).toBeVisible();
	await expect(page.getByRole('button', { name: 'Options for Test Bank •• 6789' })).toHaveCount(0);

	// The new PIN is the PIN now.
	await signIn(page, member, PASSWORD, NEW_PIN);
});
