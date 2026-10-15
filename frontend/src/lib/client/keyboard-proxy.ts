// Blueprint 41: iOS shows the on-screen keyboard only for a focus made inside
// the tap itself, and quick search's field mounts a moment after the tap. So
// the tap focuses an invisible field at once (the keyboard opens), and the
// search field takes the focus over when it mounts (moving focus between
// fields keeps the keyboard up). The stand-in is removed as soon as the real
// field has the focus, or after a second at most.

let proxy: HTMLInputElement | null = null;
let timer: ReturnType<typeof setTimeout> | undefined;

/** Call synchronously in the tap handler that opens a field-first view. */
export function holdKeyboard(): void {
	releaseKeyboard();
	const field = document.createElement('input');
	field.type = 'text';
	field.tabIndex = -1;
	field.setAttribute('aria-hidden', 'true');
	field.setAttribute('autocomplete', 'off');
	// 16 px so iOS doesn't zoom; fixed at the top so nothing scrolls to it.
	field.style.cssText =
		'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;border:0;padding:0;font-size:16px;pointer-events:none;';
	document.body.append(field);
	field.focus({ preventScroll: true });
	proxy = field;
	timer = setTimeout(releaseKeyboard, 1000);
}

/** The real field has the focus (or the view closed): drop the stand-in. */
export function releaseKeyboard(): void {
	clearTimeout(timer);
	proxy?.remove();
	proxy = null;
}

/** Was focus parked on the stand-in (so there is no trigger to return to)? */
export const isKeyboardProxy = (element: Element | null) => !!element && element === proxy;
