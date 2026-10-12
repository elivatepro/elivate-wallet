// Blueprint 35: the desktop install step's "open it on your phone" QR code
// (Paper "Install app v9" IA03), drawn as one SVG path from the module grid.

import { encode } from 'uqr';

export interface QrPath {
	/** Modules per side, quiet zone included. */
	readonly size: number;
	/** One unit square per dark module. */
	readonly d: string;
}

/** A 4-module quiet zone around the code, as phone cameras expect. */
export function qrPath(text: string): QrPath {
	const { data, size } = encode(text, { ecc: 'M', border: 4 });
	let d = '';
	data.forEach((row, y) => {
		row.forEach((dark, x) => {
			if (dark) d += `M${x} ${y}h1v1h-1z`;
		});
	});
	return { size, d };
}
