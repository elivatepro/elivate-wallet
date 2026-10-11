// Payout accounts (Y02, W-17) and leaders' invitation management (I01/I02,
// W-03). Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	completeIdentityAndProfile,
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	humanReady,
	inviteMember,
	pick,
	setJoinPassword,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

test.describe.configure({ mode: 'serial' });

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

/** Fills the PIN only when the page asks for it (step-up window lapsed). */
async function pinIfAsked(page: Page, label: string | RegExp) {
	const field = page.getByLabel(label);
	if (await field.count()) await field.fill(PIN);
}

test('payout accounts: list, add a second (cooling off), refuse a mismatch, remove', async ({
	page
}) => {
	const founder = { email: uniqueEmail('pa-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('pa-m');
	const { joinPath } = await inviteMember(founder, 'Payout Test Network', member);
	await page.goto(joinPath);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await page.goto(await confirmLinkFor(member, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await setJoinPassword(page, PASSWORD);
	await page.getByRole('button', { name: 'Accept invitation' }).click();
	await page.getByRole('link', { name: 'Let’s begin' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();
	await completeIdentityAndProfile(page);
	await pick(page.getByLabel('Bank', { exact: true }), 'Test Bank');
	await page.getByLabel('Account number').fill('0123456789');
	await page.getByRole('button', { name: 'Check account' }).click();
	await page.getByRole('button', { name: 'Save account' }).click();
	await page.getByRole('link', { name: 'Go to my wallet' }).click();
	await expect(page).toHaveURL(/\/app$/);

	// The first account: verified, no cooling-off; saving never sets primary (W-17).
	await page.goto('/app/payout-accounts');
	const list = page.getByRole('list', { name: 'Your bank accounts' });
	await expect(list.getByText('Test Bank •• 6789')).toBeVisible();
	await expect(list.getByText(/Cooling off/)).toHaveCount(0);
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Make primary: Test Bank •• 6789' }).click();
	const primary = page.getByRole('dialog', { name: 'Make this your primary account?' });
	await primary.getByLabel('Your PIN').fill(PIN);
	await primary.getByRole('button', { name: 'Make primary' }).click();
	await expect(list.getByText('Primary', { exact: true })).toBeVisible();

	// A mismatching name can't be saved.
	await page.getByRole('link', { name: 'Add bank account' }).first().click();
	await expect(page).toHaveURL(/\/app\/payout-accounts\/add$/);
	await pick(page.getByLabel('Bank', { exact: true }), 'Test Bank');
	await page.getByLabel('Account number').fill('0987654321');
	await pinIfAsked(page, 'Enter your PIN to check the account');
	await page.getByRole('button', { name: 'Check account' }).click();
	await expect(page.getByText(/Doesn’t match/)).toBeVisible();
	await expect(page.getByRole('button', { name: 'Save account' })).toHaveCount(0);
	await page.getByRole('button', { name: 'Use a different account' }).click();

	// A second matching account cools off for 24 hours.
	await pick(page.getByLabel('Bank', { exact: true }), 'Test Bank');
	await page.getByLabel('Account number').fill('1122334455');
	await pinIfAsked(page, 'Enter your PIN to check the account');
	await page.getByRole('button', { name: 'Check account' }).click();
	await expect(page.getByText('Matches your verified name')).toBeVisible();
	await page.getByRole('button', { name: 'Save account' }).click();
	// Either it saves straight away or (step-up lapsed) it asks for the PIN.
	const savePin = page.getByLabel('Enter your PIN to save the account');
	await expect(list.or(savePin)).toBeVisible();
	if (await savePin.isVisible()) {
		await savePin.fill(PIN);
		await page.getByRole('button', { name: 'Save account' }).click();
	}
	await expect(page).toHaveURL(/\/app\/payout-accounts$/);
	await expect(list.getByText('Test Bank •• 4455')).toBeVisible();
	await expect(list.getByText(/Cooling off/)).toBeVisible();

	// Remove it: reason + PIN.
	await page.getByRole('button', { name: 'Options for Test Bank •• 4455' }).click();
	await page.getByRole('menuitem', { name: 'Remove account' }).click();
	const dialog = page.getByRole('dialog', { name: 'Remove Test Bank •• 4455' });
	await dialog.getByLabel('Reason').fill('Added by mistake.');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Remove account' }).click();
	await expect(list.getByText('Test Bank •• 4455')).toHaveCount(0);
});

test('invitations: a leader sees, resends and revokes an invitation', async ({ page }) => {
	const founder = { email: uniqueEmail('inv-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const invitee = uniqueEmail('inv-m');
	await inviteMember(founder, 'Invite Test Network', invitee);
	await signInAs(page, founder.email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: /Invite Test Network.*President Team/ }).click();
	await page.goto('/app/invitations');
	await expect(page.getByText(invitee).first()).toBeVisible();
	await expect(page.getByText('Pending').first()).toBeVisible();
	await expectAccessible(page);

	// Resend: the link was issued under a minute ago, so the backend asks to wait.
	await page
		.getByRole('button', { name: `Actions for ${invitee}` })
		.first()
		.click();
	await page.getByRole('menuitem', { name: 'Resend link' }).click();
	await expect(page.getByRole('status').or(page.getByRole('alert')).first()).toBeVisible();

	// Revoke with a reason (and PIN).
	await page.keyboard.press('Escape');
	await page
		.getByRole('button', { name: `Actions for ${invitee}` })
		.first()
		.click();
	await page.getByRole('menuitem', { name: 'Revoke invitation' }).click();
	const dialog = page.getByRole('dialog', { name: 'Revoke invitation?' });
	await dialog.getByLabel('Reason').fill('Sent to the wrong office.');
	await pinIfAsked(page, 'Your PIN');
	await dialog.getByRole('button', { name: 'Revoke' }).click();
	await expect(page.getByText('Revoked').first()).toBeVisible();
});
