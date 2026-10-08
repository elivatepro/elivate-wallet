// The signed-in app is a client-rendered PWA shell (decision 36). Its HTML holds
// no user data, so it is prerendered once at build time and precached by the
// service worker; it opens offline and loads data from /api/* when online.
export const ssr = false;
export const prerender = true;
