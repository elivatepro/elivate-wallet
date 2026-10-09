// Record income (W-08; Paper T02/T05; Blueprint 09): the President records
// income for a member through the UI with a real receipt upload, and an
// unknown outcome is recovered with the same key after a reload (F-03).
// Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	fillSettled,
	completeIdentityAndProfile,
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	inviteMember,
	humanReady,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';
const RECEIPT = {
	name: 'fiverr-order-receipt.pdf',
	mimeType: 'application/pdf',
	buffer: Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n')
};

test.describe.configure({ mode: 'serial' });

async function joinAsNewMember(page: Page, joinPath: string, email: string) {
	await page.goto(joinPath);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await page.goto(await confirmLinkFor(email, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await fillSettled(page, 'New password', PASSWORD);
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

async function fillIncome(page: Page, amount: string) {
	await page.getByRole('button', { name: /Member/ }).click();
	const picker = page.getByRole('dialog', { name: 'Choose the member' });
	await picker.getByRole('button', { name: /Ada Obi/ }).click();
	await page.getByLabel('Amount received').fill(amount);
	await page.getByLabel('Source').fill('Fiverr order');
	await page.locator('input[type=file]').setInputFiles(RECEIPT);
	await expect(page.getByText('fiverr-order-receipt.pdf')).toBeVisible();
}

test('the President records income for a member with a receipt', async ({ page }) => {
	const founder = { email: uniqueEmail('income-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('income-m');
	const { joinPath } = await inviteMember(founder, 'Income Test Network', member);
	await joinAsNewMember(page, joinPath, member);
	// A member can't record income: no nav entry.
	await expect(page.getByRole('link', { name: 'Record income' })).toHaveCount(0);

	await asPresident(page, founder.email, 'Income Test Network');
	await page.getByRole('link', { name: 'Record income' }).first().click();
	await expect(page).toHaveURL(/\/app\/income$/);

	// Nothing chosen yet: local validation, nothing sent.
	await page.getByRole('button', { name: 'Post income' }).last().click();
	await expect(page.getByText('Choose the member.')).toBeVisible();
	await expect(page.getByText('Add the receipt.')).toBeVisible();

	await fillIncome(page, '1000');
	// Exact preview with the default split 40/10/15/25/10.
	const preview = page.getByRole('complementary', { name: 'What they will receive' });
	await expect(preview.getByText('+₦1,000.00')).toBeVisible();
	await expect(preview.getByText('₦400.00')).toBeVisible();
	await expect(preview.getByText('₦250.00')).toBeVisible();
	await expectAccessible(page);

	await page.getByRole('button', { name: 'Post ₦1,000.00' }).last().click();
	const dialog = page.getByRole('dialog', { name: 'Post this income?' });
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Post ₦1,000.00' }).click();

	await expect(page.getByRole('heading', { name: 'Income posted' })).toBeVisible();
	await expect(page.getByText(/^INC-[0-9A-Z]{4}-[0-9A-Z]{4}$/)).toBeVisible();
	await expect(page.getByText('Point Value · 40%')).toBeVisible();
	await expectAccessible(page);

	// The member sees it on Home.
	await signInAs(page, member);
	await expect(
		page.getByRole('region', { name: 'Balance' }).getByText('₦1,000.00', { exact: true })
	).toBeVisible();
});

test('an unknown outcome survives a reload and is recovered with the same key', async ({
	page
}) => {
	const founder = { email: uniqueEmail('unknown-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('unknown-m');
	const { joinPath } = await inviteMember(founder, 'Unknown Test Network', member);
	await joinAsNewMember(page, joinPath, member);
	await asPresident(page, founder.email, 'Unknown Test Network');
	await page.goto('/app/income');
	await fillIncome(page, '2500.50');

	// The command reaches the server, but the answer is lost on the way back.
	await page.route('**/api/income', async (route) => {
		await route.fetch();
		await route.abort('failed');
	});
	await page.getByRole('button', { name: 'Post ₦2,500.50' }).last().click();
	const dialog = page.getByRole('dialog', { name: 'Post this income?' });
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Post ₦2,500.50' }).click();
	await expect(page.getByRole('heading', { name: 'Checking what happened' })).toBeVisible();
	await page.unroute('**/api/income');

	await page.reload();
	await expect(page.getByRole('heading', { name: 'Checking what happened' })).toBeVisible();
	await expect(page.getByText('₦2,500.50')).toBeVisible();
	await page.getByRole('button', { name: 'Check again' }).click();
	await expect(page.getByRole('heading', { name: 'Income posted' })).toBeVisible();

	// Posted once: the member's balance is the single income.
	await signInAs(page, member);
	await expect(
		page.getByRole('region', { name: 'Balance' }).getByText('₦2,500.50', { exact: true })
	).toBeVisible();
});

test('Record income fits 320 px and has the mobile close bar', async ({ page }) => {
	const founder = { email: uniqueEmail('narrow-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await inviteMember(founder, 'Narrow Test Network', uniqueEmail('narrow-m'));
	await asPresident(page, founder.email, 'Narrow Test Network');
	await page.setViewportSize({ width: 320, height: 720 });
	await page.goto('/app/income');
	await expect(page.getByRole('link', { name: 'Close' })).toBeVisible();
	await expectNoHorizontalScroll(page);
});
