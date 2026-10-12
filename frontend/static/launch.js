// Blueprint 35: the launch animation (app.html) plays once per app session,
// when the installed app opens. Later full page loads skip it. A file, not an
// inline script, so the nonce/hash CSP needs no exception.
try {
	if (sessionStorage.getItem('ew:launched')) document.documentElement.classList.add('ew-launched');
	else sessionStorage.setItem('ew:launched', '1');
} catch {
	document.documentElement.classList.add('ew-launched');
}
