// Synthetic wire fixtures shaped exactly like the backend on main
// (api.security_state, api.my_workspaces, api.my_capabilities and the
// _shared/http.ts envelope). Test-only; no real data.

export const securityStateReady = {
	gate: 'ready',
	uid: 'EW-10042',
	accountStatus: 'active',
	attemptsRemaining: 5,
	stepUpExpiresAt: '2026-10-08T09:05:00.123456+00:00'
};

export const securityStateSetup = {
	gate: 'pin_setup_required',
	uid: 'EW-10043',
	accountStatus: 'active',
	attemptsRemaining: 5,
	stepUpExpiresAt: null
};

export const workspace = {
	membershipId: '6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40',
	tenantId: '1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
	tenantName: 'Sunrise Network',
	tenantShortName: 'Sunrise',
	tenantStatus: 'pending_payment',
	officeId: null,
	officeName: null,
	officeType: null,
	role: 'president_team_member',
	status: 'active',
	isPrimary: true
};

export const capabilities = {
	membershipId: workspace.membershipId,
	tenantStatus: 'pending_payment',
	permissions: ['manage_offices', 'view_audit', 'some_future_permission']
};

export const success = (data: unknown) => ({
	ok: true,
	data,
	requestId: '0e6c2b9a-1f3d-4c5e-8a7b-9c0d1e2f3a4b'
});

export const failure = (
	code: string,
	details: Record<string, unknown> = {},
	retryable = code === 'internal_error' || code === 'rate_limited'
) => ({
	ok: false,
	error: { code, message: 'Message from the backend.', retryable, details },
	requestId: '7f8e9d0c-1b2a-4c3d-9e8f-7a6b5c4d3e2f'
});
