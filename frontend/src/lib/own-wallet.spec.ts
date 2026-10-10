import { describe, expect, it } from 'vitest';
import { ownWalletBlocked, ownWalletPermission } from '#lib/own-wallet.js';

const MEMBER = [
	'view_own_wallet',
	'view_own_financials',
	'export_own_statement',
	'initiate_own_withdrawal',
	'manage_own_payout_accounts',
	'transfer_between_own_pockets'
];
// A-03: the President Team holds none of the own-wallet permissions.
const PRESIDENT = ['view_managed_wallets', 'record_income', 'invite_members', 'manage_allocation'];

describe('own-money pages', () => {
	it('names the permission each own-money page needs', () => {
		expect(ownWalletPermission('/app/payout-accounts')).toBe('manage_own_payout_accounts');
		expect(ownWalletPermission('/app/payout-accounts/add')).toBe('manage_own_payout_accounts');
		expect(ownWalletPermission('/app/withdrawals/new/')).toBe('initiate_own_withdrawal');
		expect(ownWalletPermission('/app/split/move')).toBe('transfer_between_own_pockets');
		expect(ownWalletPermission('/app/split')).toBeNull();
		expect(ownWalletPermission('/app/invitations')).toBeNull();
		expect(ownWalletPermission('/app/payout-accountsx')).toBeNull();
	});

	it('blocks them for a wallet-less workspace only', () => {
		for (const path of ['/app/payout-accounts', '/app/activity', '/app/statements']) {
			expect(ownWalletBlocked(path, PRESIDENT), path).toBe(true);
			expect(ownWalletBlocked(path, MEMBER), path).toBe(false);
		}
		expect(ownWalletBlocked('/app/invitations', PRESIDENT)).toBe(false);
		expect(ownWalletBlocked('/app/split', PRESIDENT)).toBe(false);
	});

	it('never blocks before the permissions are known', () => {
		expect(ownWalletBlocked('/app/payout-accounts', null)).toBe(false);
	});
});
