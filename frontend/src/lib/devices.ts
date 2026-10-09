// Device rows for Devices & sessions (Paper S03/S04, B09/B10). The backend
// gives only the browser's user agent and times (no IP or location,
// Blueprint 01 B4), so the label is a best-effort "Device · Browser".

export type DeviceKind = 'phone' | 'tablet' | 'laptop';

export interface DeviceLabel {
	readonly kind: DeviceKind;
	readonly label: string;
}

function deviceOf(ua: string): { name: string; kind: DeviceKind } {
	if (/iPad/.test(ua)) return { name: 'iPad', kind: 'tablet' };
	if (/iPhone/.test(ua)) return { name: 'iPhone', kind: 'phone' };
	if (/Android/.test(ua)) {
		return /Mobile/.test(ua)
			? { name: 'Android phone', kind: 'phone' }
			: { name: 'Android tablet', kind: 'tablet' };
	}
	if (/Macintosh|Mac OS X/.test(ua)) return { name: 'Mac', kind: 'laptop' };
	if (/Windows/.test(ua)) return { name: 'Windows', kind: 'laptop' };
	if (/CrOS/.test(ua)) return { name: 'Chromebook', kind: 'laptop' };
	if (/Linux/.test(ua)) return { name: 'Linux', kind: 'laptop' };
	return { name: 'Unknown device', kind: 'laptop' };
}

function browserOf(ua: string): string | null {
	if (/Edg\//.test(ua)) return 'Edge';
	if (/OPR\/|Opera/.test(ua)) return 'Opera';
	if (/SamsungBrowser/.test(ua)) return 'Samsung Internet';
	if (/Firefox\/|FxiOS/.test(ua)) return 'Firefox';
	if (/Chrome\/|CriOS/.test(ua)) return 'Chrome';
	if (/Safari\//.test(ua)) return 'Safari';
	return null;
}

export function describeDevice(userAgent: string | null): DeviceLabel {
	const ua = userAgent ?? '';
	const device = deviceOf(ua);
	const browser = browserOf(ua);
	return { kind: device.kind, label: browser ? `${device.name} · ${browser}` : device.name };
}

interface DateOptions {
	readonly locale?: string;
	readonly timeZone?: string;
}

/** "Active now" (under 5 minutes), "Active 2 hours ago" (under a day), else "Active 4 Oct, 18:05". */
export function activityLabel(
	iso: string | null,
	now: number,
	{ locale, timeZone }: DateOptions = {},
	short = false
): string {
	if (!iso) return short ? '' : 'Active recently';
	const at = Date.parse(iso);
	const minutes = Math.max(0, Math.floor((now - at) / 60_000));
	if (minutes < 5) return short ? 'now' : 'Active now';
	if (minutes < 60) return short ? `${minutes} min ago` : `Active ${minutes} minutes ago`;
	const hours = Math.floor(minutes / 60);
	if (hours < 24) {
		return short ? `${hours} h ago` : `Active ${hours} hour${hours === 1 ? '' : 's'} ago`;
	}
	const date = new Date(at);
	const day = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short', timeZone }).format(
		date
	);
	if (short) return day;
	const time = new Intl.DateTimeFormat(locale, {
		hour: '2-digit',
		minute: '2-digit',
		hourCycle: 'h23',
		timeZone
	}).format(date);
	return `Active ${day}, ${time}`;
}

/** "AN" from a name; null when there is no name. */
export function initials(name: string | null): string | null {
	const parts = (name ?? '').trim().split(/\s+/).filter(Boolean);
	if (parts.length === 0) return null;
	const first = parts[0]?.[0] ?? '';
	const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : '';
	return (first + last).toUpperCase();
}

/** "+234 •• •••• 4410": phone masked to the last 4 digits (Paper B09). */
export function maskPhone(phone: string | null): string | null {
	if (!phone) return null;
	const digits = phone.replace(/[^0-9]/g, '');
	const last4 = digits.slice(-4);
	const prefix = phone.startsWith('+') ? `+${digits.slice(0, 3)} ` : '';
	return `${prefix}•• •••• ${last4}`;
}
