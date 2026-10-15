// Blueprint 41: the working label of a command button.
import { describe, expect, it } from 'vitest';
import { busyLabel } from './busy-label.js';

describe('busy label', () => {
	it('turns the command into what is happening', () => {
		expect(busyLabel('Save changes')).toBe('Saving…');
		expect(busyLabel('Submit adjustment')).toBe('Submitting…');
		expect(busyLabel('Cancel request')).toBe('Cancelling…');
		expect(busyLabel('Approve')).toBe('Approving…');
		expect(busyLabel('Reject')).toBe('Rejecting…');
		expect(busyLabel('Send for checking')).toBe('Sending…');
		expect(busyLabel('Pay ₦25,000.00')).toBe('Paying…');
		expect(busyLabel('Create and invite')).toBe('Creating…');
		expect(busyLabel('Download CSV')).toBe('Downloading…');
	});

	it('keeps a particle', () => {
		expect(busyLabel('Sign out others')).toBe('Signing out…');
	});

	it('says "Working…" for labels that are not commands', () => {
		expect(busyLabel('Got it')).toBe('Working…');
		expect(busyLabel('')).toBe('Working…');
	});
});
