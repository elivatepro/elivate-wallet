// Withdrawals and pocket moves (W-09–W-11, W-13; Blueprint 11): a member
// requests a withdrawal with their PIN, the President approves it, reveals
// the destination, records the payout with a receipt, and the receipt check
// (stubbed in the local database: no OpenAI call) matches, completing it. A
// pocket move is requested and approved. Local stack only, synthetic data.

import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	recordIncome,
	shot,
	finishCheck,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const RECEIPT = {
	name: 'access-transfer.pdf',
	mimeType: 'application/pdf',
	buffer: Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n')
};

test.describe.configure({ mode: 'serial' });

test('a withdrawal is requested, approved, paid out and verified', async ({ page }) => {
	const founder = { email: uniqueEmail('wd-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('wd-m');
	await memberWithAccount(founder, 'Withdraw Test Network', member);
	await signInAs(page, member);
	await recordIncome(founder, member, '10000.00');

	// Member: M06 → M07 (PIN) → M08.
	await page.goto('/app/withdrawals');
	await expect(page.getByRole('heading', { name: '₦0.00' })).toBeVisible();
	await page.getByRole('link', { name: 'New withdrawal' }).click();
	await expect(page.getByRole('heading', { name: 'Withdraw to your bank' })).toBeVisible();
	await page.getByRole('radio', { name: /Point Value/ }).click();
	await page.getByLabel('Amount').fill('999999');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await expect(page.getByText(/You can withdraw up to/).first()).toBeVisible();
	await page.getByLabel('Amount').fill('1500');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await expect(page.getByRole('heading', { name: 'Review your withdrawal' })).toBeVisible();
	await expectAccessible(page);
	// Blueprint 40: the reason is required; the button stays tappable and points at the field.
	const reason = page.getByLabel('What’s this withdrawal for?');
	await page.getByRole('button', { name: 'Submit request' }).click();
	await expect(
		page.getByText('Say what this withdrawal is for (at least 3 characters).')
	).toBeVisible();
	await expect(reason).toBeFocused();
	await expect(page.getByRole('dialog', { name: 'Enter your transaction PIN' })).toHaveCount(0);
	await reason.fill('School fees for the second term');
	// Going back to the amount keeps the note.
	await page.getByRole('button', { name: 'Edit amount' }).click();
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await expect(reason).toHaveValue('School fees for the second term');
	await page.getByRole('button', { name: 'Submit request' }).click();
	const pin = page.getByRole('dialog', { name: 'Enter your transaction PIN' });
	await pin.getByLabel('Your PIN').fill(PIN);
	await pin.getByRole('button', { name: 'Submit request' }).click();
	await expect(page.getByRole('heading', { name: 'Request sent' })).toBeVisible();
	// Blueprint 44 (D7): one line, then the withdrawal itself.
	await expect(page.getByText('₦1,500.00 is on hold until it’s approved.')).toBeVisible();
	await expect(page.getByText(/^Reference WDR-/)).toBeVisible();
	await shot(page, 'WF-sent');
	await page.getByRole('link', { name: 'View withdrawal' }).click();
	// Desktop: the list with the side panel (WF04); the link works as a deep link too.
	await expect(page).toHaveURL(/\/app\/withdrawals\?w=[0-9a-f-]{36}$/);
	const detail = page.getByRole('complementary', { name: 'Withdrawal' });
	await expect(detail.getByText('Waiting for approval')).toBeVisible();
	await expect(detail.getByText('With your team leader')).toBeVisible();
	await expect(detail.getByText('School fees for the second term')).toBeVisible();
	await expect(detail.getByRole('button', { name: 'Cancel withdrawal' })).toBeVisible();
	await expect(page.getByRole('heading', { name: '₦1,500.00' })).toBeVisible();
	const row = page.locator('a.wd-row[aria-current="true"]');
	await expect(row).toContainText('•• 6789');
	await expectAccessible(page);
	await shot(page, 'WF04-panel');
	const withdrawalId = new URL(page.url()).searchParams.get('w') ?? '';

	// D1: Home's Recent activity shows it as Requested, on hold, and opens it.
	await page.goto('/app');
	const open = page.getByRole('link', { name: /•• 6789.*Requested/ });
	await expect(open).toBeVisible();
	await expect(open).toContainText('₦1,500.00');
	await expect(open).not.toContainText('−₦1,500.00');
	// …and so does Activity, in its Open group.
	await page.goto('/app/activity');
	await expect(page.getByRole('heading', { name: 'Open' })).toBeVisible();
	await expect(page.getByRole('link', { name: /•• 6789/ }).first()).toBeVisible();

	// Phone: the row opens the full page (WF01), and Back returns to the list.
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/app/withdrawals');
	await page.locator('a.wd-row').first().click();
	await expect(page).toHaveURL(new RegExp(`/app/withdrawals/${withdrawalId}$`));
	await expect(page.getByRole('heading', { name: 'Withdrawal', exact: true })).toBeVisible();
	await expect(page.getByText(/^To .*•• 6789$/)).toBeVisible();
	await shot(page, 'WF01-page');
	await page.getByRole('button', { name: 'Back to withdrawals' }).click();
	await expect(page).toHaveURL(/\/app\/withdrawals$/);
	await page.setViewportSize({ width: 1280, height: 720 });

	// D3: the President switches on "One open withdrawal at a time"…
	await asPresident(page, founder.email, 'Withdraw Test Network');
	await page.goto('/app/settings/details');
	const rule = page.getByRole('switch', { name: 'One open withdrawal at a time' });
	await expect(rule).toHaveAttribute('aria-checked', 'false');
	await rule.click();
	await page.getByRole('button', { name: 'Save changes' }).click();
	const save = page.getByRole('dialog');
	await save.getByLabel('Your PIN').fill(PIN);
	await save.getByRole('button', { name: 'Save changes' }).click();
	await expect(page.getByText('Saved.')).toBeVisible();
	await expect(page.getByText('Withdrawal rule changed')).toBeVisible();
	// …and New withdrawal says so before any form.
	await signInAs(page, member);
	await page.goto('/app/withdrawals/new');
	await expect(
		page.getByRole('heading', { name: 'Your withdrawal of ₦1,500.00 is still open.' })
	).toBeVisible();
	await expect(page.getByLabel('Amount')).toHaveCount(0);
	await page.getByRole('link', { name: 'View withdrawal' }).click();
	await expect(page).toHaveURL(/\/app\/withdrawals\?w=/);

	// President: C01 approve → U01 reveal (PIN) → U02 record → C05 checking.
	await asPresident(page, founder.email, 'Withdraw Test Network');
	await page.getByRole('link', { name: 'Withdrawal queue' }).first().click();
	const panel = page.getByRole('region', { name: /Withdrawal WDR-/ });
	await expect(panel.getByText('₦1,500.00').first()).toBeVisible();
	// Blueprint 40 (Paper WR02): the approver sees what it is for.
	await expect(panel.getByText('“School fees for the second term”')).toBeVisible();
	await expectAccessible(page);
	await panel.getByRole('button', { name: 'Approve' }).click();
	await expect(page.getByText(/^Approved\./)).toBeVisible();
	// The sign-in PIN opened a fresh 5-minute proof, so the PIN is asked only if it lapsed.
	await panel.getByRole('button', { name: 'Reveal' }).click();
	const revealPin = page.getByRole('dialog', { name: 'Show account number' });
	await expect(panel.getByText('0123456789').or(revealPin)).toBeVisible();
	if (await revealPin.isVisible()) {
		await shot(page, 'U01-reveal-pin');
		await revealPin.getByLabel('Your PIN').fill(PIN);
		await revealPin.getByRole('button', { name: 'Show number' }).click();
	}
	await expect(panel.getByText('0123456789')).toBeVisible();
	await expect(panel.getByRole('button', { name: 'Hide' })).toBeVisible();

	await panel.getByLabel('Amount sent').fill('1450');
	await panel.getByLabel('Bank reference').fill('000014261005173300');
	await panel.getByLabel('Bank fee (optional)').fill('50');
	await panel.locator('input[type=file]').setInputFiles(RECEIPT);
	await expect(panel.getByText('access-transfer.pdf')).toBeVisible();
	await shot(page, 'U02-revealed-record');
	await panel.getByRole('button', { name: 'Submit for verification' }).click();
	await expect(page.getByText(/^Sent for verification/)).toBeVisible();
	await page.getByRole('tab', { name: /Verifying/ }).click();
	await expect(panel.getByText('Checking receipt')).toBeVisible();

	// The receipt shows another date (stubbed worker): U03, the one fix keeps the receipt.
	finishCheck(member, 'date-mismatch');
	await page.getByRole('tab', { name: /Needs action/ }).click();
	await expect(panel.getByText('Correction needed · 1 left')).toBeVisible();
	await panel.getByRole('button', { name: 'Fix the date' }).click();
	const fix = page.getByRole('dialog', { name: 'Fix the date' });
	await expect(fix.getByLabel('Date paid')).toBeVisible();
	await shot(page, 'U03-fix-date');
	await fix.getByLabel('Your PIN').fill(PIN);
	await fix.getByRole('button', { name: 'Send again' }).click();
	await expect(page.getByText(/^Sent again\./)).toBeVisible();

	// The second check matches, completing the withdrawal (U04).
	finishCheck(member);
	await page.getByRole('tab', { name: 'Completed' }).click();
	await expect(panel.getByText('Completed', { exact: true })).toBeVisible();
	await expect(page.getByRole('heading', { name: '₦1,500.00 paid out' })).toBeVisible();
	await shot(page, 'U04-completed');

	await signInAs(page, member);
	await page.goto('/app/withdrawals');
	await expect(page.getByText('−₦1,500.00')).toBeVisible();
});

test('a pocket move is requested and approved', async ({ page }) => {
	const founder = { email: uniqueEmail('mv-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('mv-m');
	await memberWithAccount(founder, 'Move Test Network', member);
	await signInAs(page, member);
	await recordIncome(founder, member, '1000.00');

	await page.goto('/app');
	await page.getByRole('link', { name: 'Move money' }).first().click();
	await expect(page.getByRole('heading', { name: 'Move between pockets' })).toBeVisible();
	const from = page.getByRole('radiogroup', { name: 'From pocket' });
	const to = page.getByRole('radiogroup', { name: 'To pocket' });
	await from.getByRole('radio', { name: /Point Value/ }).click();
	await to.getByRole('radio', { name: /Savings/ }).click();
	await page.getByLabel('Amount').fill('100');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await page.getByRole('button', { name: 'Send request' }).click();
	await expect(page.getByRole('heading', { name: 'Move requested' })).toBeVisible();
	await expect(
		page.getByText(/from Point Value to Savings is held until your leader approves/)
	).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'MV01-move-requested');

	await asPresident(page, founder.email, 'Move Test Network');
	await page.getByRole('link', { name: 'Pocket moves' }).first().click();
	const panel = page.getByRole('region', { name: /Pocket move PTR-/ });
	await expect(panel.getByText('Point Value', { exact: true })).toBeVisible();
	await panel.getByRole('button', { name: 'Approve & move' }).click();
	await expect(page.getByText(/^Moved ₦100\.00 from Point Value to Savings\./)).toBeVisible();
});
